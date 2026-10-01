package remote

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/hpke"
	"encoding/binary"
	"errors"

	"github.com/coder/websocket"
)

// Channel framing (contract "Framing and encryption"):
//
//	hello (client, first):  "LFR1" | enc(32) | seq=0 (8, BE) | Seal(aad = "LFR1" || seq, hello JSON)
//	first server frame:     enc_s2c(32) | seq=0 (8, BE) | Seal(aad = seq, plaintext)
//	every later frame:      seq (8, BE) | Seal(aad = seq, plaintext)
//
// Every plaintext except the hello starts with a kind byte: 0x00 control JSON
// (at most 65,536 bytes), 0x01 audio (1…16,000 f32le samples) or 0x02
// samples (1…32,000 s16le samples, Feature 018), the last two client to
// server only. The server-to-client context is an HPKE sender to the hello's
// reply_key with info = c2s.Export("localflow v1 s2c info", 32), so only a
// holder of the client-to-server context can derive it.
const (
	ChannelInfo           = "localflow remote v1"
	HelloMagic            = "LFR1"
	MaxBinaryMessage      = 70000
	KindControl      byte = 0x00
	KindAudio        byte = 0x01
	KindSamples      byte = 0x02
	// MaxSampleFrameSamples bounds one kind 0x02 frame (64,000 bytes).
	MaxSampleFrameSamples = 32000
	// CloseHelloRefused is the WebSocket close code for a hello the server
	// cannot open; the client reports pin_mismatch.
	CloseHelloRefused websocket.StatusCode = 4001

	s2cInfoLabel = "localflow v1 s2c info"
	bindingLabel = "localflow v1 binding"
	encLength    = 32
	seqLength    = 8
	exportLength = 32
)

var (
	// ErrChannelFailed marks a frame that failed to open or arrived out of
	// sequence. The channel is unusable afterwards and closes with no reply.
	ErrChannelFailed = errors.New("remote: channel failed")
	// ErrHelloRefused marks a hello that could not be opened: close code 4001.
	ErrHelloRefused = errors.New("remote: hello refused")
)

var (
	kem  = hpke.DHKEM(ecdh.X25519())
	kdf  = hpke.HKDFSHA256()
	aead = hpke.ChaCha20Poly1305()
)

// Frame is one decrypted plaintext after the hello.
type Frame struct {
	Kind    byte
	Payload []byte
}

func (f Frame) plaintext() []byte { return append([]byte{f.Kind}, f.Payload...) }

type opener interface {
	Open(aad, ciphertext []byte) ([]byte, error)
}

type sealer interface {
	Seal(aad, plaintext []byte) ([]byte, error)
}

// Channel is the sealed state of one WebSocket, independent of the socket so
// the framing can be tested without one. It is not safe for concurrent use:
// the caller serializes Seal calls with writes and Open calls with reads.
type Channel struct {
	client     bool
	receive    opener
	send       sealer
	receiveSeq uint64
	sendSeq    uint64
	helloSent  bool
	pendingEnc []byte // server: enc_s2c, prefixed to the first sealed frame
	replyKey   hpke.PrivateKey
	s2cInfo    []byte
	binding    []byte
	failed     bool
}

// OpenHello opens the first client message with the server's identity key.
// Any failure is ErrHelloRefused. The returned channel can open client frames;
// Accept must be called before it can seal.
func OpenHello(key hpke.PrivateKey, message []byte) (*Channel, []byte, error) {
	header := len(HelloMagic) + encLength + seqLength
	if len(message) > MaxBinaryMessage || len(message) <= header || string(message[:len(HelloMagic)]) != HelloMagic {
		return nil, nil, ErrHelloRefused
	}
	enc := message[len(HelloMagic) : len(HelloMagic)+encLength]
	seq := message[len(HelloMagic)+encLength : header]
	if binary.BigEndian.Uint64(seq) != 0 {
		return nil, nil, ErrHelloRefused
	}
	recipient, err := hpke.NewRecipient(enc, key, kdf, aead, []byte(ChannelInfo))
	if err != nil {
		return nil, nil, ErrHelloRefused
	}
	aad := append([]byte(HelloMagic), seq...)
	plaintext, err := recipient.Open(aad, message[header:])
	if err != nil {
		return nil, nil, ErrHelloRefused
	}
	c := &Channel{receive: recipient, receiveSeq: 1}
	if c.s2cInfo, err = recipient.Export(s2cInfoLabel, exportLength); err != nil {
		return nil, nil, ErrHelloRefused
	}
	if c.binding, err = recipient.Export(bindingLabel, exportLength); err != nil {
		return nil, nil, ErrHelloRefused
	}
	return c, plaintext, nil
}

// Accept builds the server-to-client sender to the hello's reply key. The next
// Seal writes the first server frame, prefixed with enc_s2c.
func (c *Channel) Accept(replyKey []byte) error {
	if c.client || c.send != nil || c.s2cInfo == nil || len(replyKey) != KeyBytes {
		return invalid("reply key refused")
	}
	public, err := kem.NewPublicKey(replyKey)
	if err != nil {
		return invalid("reply key refused")
	}
	enc, sender, err := hpke.NewSender(public, kdf, aead, c.s2cInfo)
	if err != nil {
		return invalid("reply key refused")
	}
	c.send, c.pendingEnc = sender, enc
	return nil
}

// NewClient starts the client side of a channel to serverKey (raw X25519
// public key). replyKey is the per-channel key named in the hello. flowd uses
// it only in tests and tools; the macOS client implements the same with
// CryptoKit.
func NewClient(serverKey []byte, replyKey hpke.PrivateKey) (*Channel, error) {
	public, err := kem.NewPublicKey(serverKey)
	if err != nil {
		return nil, invalid("server key refused")
	}
	enc, sender, err := hpke.NewSender(public, kdf, aead, []byte(ChannelInfo))
	if err != nil {
		return nil, err
	}
	c := &Channel{client: true, send: sender, replyKey: replyKey, pendingEnc: enc}
	if c.s2cInfo, err = sender.Export(s2cInfoLabel, exportLength); err != nil {
		return nil, err
	}
	if c.binding, err = sender.Export(bindingLabel, exportLength); err != nil {
		return nil, err
	}
	return c, nil
}

// Hello seals the client's first message.
func (c *Channel) Hello(plaintext []byte) ([]byte, error) {
	if !c.client || c.helloSent || c.failed {
		return nil, ErrChannelFailed
	}
	seq := binary.BigEndian.AppendUint64(nil, 0)
	aad := append([]byte(HelloMagic), seq...)
	ciphertext, err := c.send.Seal(aad, plaintext)
	if err != nil {
		return nil, err
	}
	c.helloSent, c.sendSeq = true, 1
	message := append([]byte(HelloMagic), c.pendingEnc...)
	c.pendingEnc = nil
	message = append(message, seq...)
	return append(message, ciphertext...), nil
}

// Binding is Export("localflow v1 binding", 32) on the client-to-server
// context: the OIDC nonce and device signatures are bound to it.
func (c *Channel) Binding() []byte { return bytes.Clone(c.binding) }

// Seal encrypts one frame with the next send sequence number.
func (c *Channel) Seal(f Frame) ([]byte, error) {
	switch {
	case f.Kind == KindControl && len(f.Payload) <= MaxControlBytes:
	case f.Kind == KindAudio && c.client && validAudio(f.Payload) == nil:
	case f.Kind == KindSamples && c.client && validSamples(f.Payload) == nil:
	default:
		return nil, invalid("frame not sendable")
	}
	return c.sealPlaintext(f.plaintext())
}

func (c *Channel) sealPlaintext(plaintext []byte) ([]byte, error) {
	if c.failed || c.send == nil || (c.client && !c.helloSent) {
		return nil, ErrChannelFailed
	}
	seq := binary.BigEndian.AppendUint64(nil, c.sendSeq)
	ciphertext, err := c.send.Seal(seq, plaintext)
	if err != nil {
		c.failed = true
		return nil, ErrChannelFailed
	}
	c.sendSeq++
	var message []byte
	if !c.client && c.pendingEnc != nil {
		message, c.pendingEnc = append(message, c.pendingEnc...), nil
	}
	message = append(message, seq...)
	return append(message, ciphertext...), nil
}

// Open decrypts one received message. A message that is oversized, out of
// sequence or fails to open returns ErrChannelFailed and fails the channel for
// good. An authentic frame whose payload breaks the kind rules returns an
// *Error (invalid_message or limit_exceeded) and leaves the counters in step.
func (c *Channel) Open(message []byte) (Frame, error) {
	if c.failed {
		return Frame{}, ErrChannelFailed
	}
	frame, err := c.open(message)
	if err != nil {
		c.failed = true
		return Frame{}, ErrChannelFailed
	}
	return frame, validateFrame(frame, c.client)
}

func (c *Channel) open(message []byte) (Frame, error) {
	if len(message) > MaxBinaryMessage {
		return Frame{}, ErrChannelFailed
	}
	if c.client && c.receive == nil {
		// First server frame: enc_s2c | seq | ciphertext.
		if len(message) < encLength+seqLength {
			return Frame{}, ErrChannelFailed
		}
		recipient, err := hpke.NewRecipient(message[:encLength], c.replyKey, kdf, aead, c.s2cInfo)
		if err != nil {
			return Frame{}, ErrChannelFailed
		}
		c.receive, message = recipient, message[encLength:]
	}
	if c.receive == nil || len(message) < seqLength || binary.BigEndian.Uint64(message[:seqLength]) != c.receiveSeq {
		return Frame{}, ErrChannelFailed
	}
	plaintext, err := c.receive.Open(message[:seqLength], message[seqLength:])
	if err != nil {
		return Frame{}, ErrChannelFailed
	}
	c.receiveSeq++
	if len(plaintext) == 0 {
		return Frame{Kind: 0xff}, nil
	}
	return Frame{Kind: plaintext[0], Payload: plaintext[1:]}, nil
}

func validateFrame(f Frame, client bool) error {
	switch f.Kind {
	case KindControl:
		if len(f.Payload) > MaxControlBytes {
			return &Error{CodeLimitExceeded, "control message over 65,536 bytes"}
		}
		return nil
	case KindAudio:
		if client {
			return invalid("audio from the server")
		}
		return validAudio(f.Payload)
	case KindSamples:
		if client {
			return invalid("samples from the server")
		}
		return validSamples(f.Payload)
	default:
		return invalid("unknown frame kind")
	}
}

func validAudio(payload []byte) error {
	switch {
	case len(payload) == 0 || len(payload)%4 != 0:
		return invalid("audio not whole f32le samples")
	case len(payload)/4 > MaxAudioSamples:
		return &Error{CodeLimitExceeded, "audio frame over 16,000 samples"}
	}
	return nil
}

// validSamples accepts 1…32,000 whole s16le samples. Unlike f32le, an
// oversized frame is invalid_message (Feature 018 contract).
func validSamples(payload []byte) error {
	if len(payload) == 0 || len(payload)%2 != 0 || len(payload)/2 > MaxSampleFrameSamples {
		return invalid("samples not 1…32,000 whole s16le samples")
	}
	return nil
}

// socket adapts a coder/websocket connection to the channel's transport rules:
// binary messages only (a text message closes with 1003) and at most 70,000
// bytes (the library closes with 1009).
type socket struct{ ws *websocket.Conn }

var errTextMessage = errors.New("remote: text message")

func newSocket(ws *websocket.Conn) *socket {
	ws.SetReadLimit(MaxBinaryMessage)
	return &socket{ws}
}

func (s *socket) read(ctx context.Context) ([]byte, error) {
	kind, data, err := s.ws.Read(ctx)
	if err != nil {
		return nil, err
	}
	if kind != websocket.MessageBinary {
		s.close(websocket.StatusUnsupportedData)
		return nil, errTextMessage
	}
	return data, nil
}

func (s *socket) write(ctx context.Context, message []byte) error {
	return s.ws.Write(ctx, websocket.MessageBinary, message)
}

func (s *socket) close(code websocket.StatusCode) { _ = s.ws.Close(code, "") }

// acceptHello reads the first message and opens it. A hello that cannot be
// opened closes the socket with 4001 and nothing else.
func acceptHello(ctx context.Context, s *socket, key hpke.PrivateKey) (*Channel, []byte, error) {
	message, err := s.read(ctx)
	if err != nil {
		return nil, nil, err
	}
	channel, plaintext, err := OpenHello(key, message)
	if err != nil {
		s.close(CloseHelloRefused)
		return nil, nil, err
	}
	return channel, plaintext, nil
}
