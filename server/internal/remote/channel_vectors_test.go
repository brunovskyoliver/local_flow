package remote

import (
	"bytes"
	"crypto/ecdh"
	"crypto/hpke"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"math"
	"os"
	"testing"
	"testing/cryptotest"
)

var update = flag.Bool("update", false, "rewrite fixtures/remote/hpke-vectors.json")

const vectorsPath = "../../../fixtures/remote/hpke-vectors.json"

// vectorFrame is one sealed frame after the hello. Every byte string is hex.
type vectorFrame struct {
	Seq       uint64 `json:"seq"`
	Kind      string `json:"kind"`
	AAD       string `json:"aad"`
	Plaintext string `json:"plaintext"`
	Frame     string `json:"frame"`
}

type vectors struct {
	Description      string `json:"description"`
	Encoding         string `json:"encoding"`
	Suite            string `json:"suite"`
	Mode             string `json:"mode"`
	KEMID            int    `json:"kem_id"`
	KDFID            int    `json:"kdf_id"`
	AEADID           int    `json:"aead_id"`
	InfoText         string `json:"info_text"`
	Info             string `json:"info"`
	ServerPrivateKey string `json:"server_private_key"`
	ServerPublicKey  string `json:"server_public_key"`
	ReplyPrivateKey  string `json:"reply_private_key"`
	ReplyPublicKey   string `json:"reply_public_key"`
	Hello            struct {
		Enc       string `json:"enc"`
		Seq       uint64 `json:"seq"`
		AAD       string `json:"aad"`
		Plaintext string `json:"plaintext"`
		Frame     string `json:"frame"`
	} `json:"hello"`
	Exports struct {
		S2CInfoLabel string `json:"s2c_info_label"`
		S2CInfo      string `json:"s2c_info"`
		BindingLabel string `json:"binding_label"`
		Binding      string `json:"binding"`
	} `json:"exports"`
	ServerFirst struct {
		Enc       string `json:"enc"`
		Seq       uint64 `json:"seq"`
		Kind      string `json:"kind"`
		AAD       string `json:"aad"`
		Plaintext string `json:"plaintext"`
		Frame     string `json:"frame"`
	} `json:"server_first"`
	C2S []vectorFrame `json:"c2s"`
	S2C []vectorFrame `json:"s2c"`
}

// fixedKey derives a test-only X25519 private key from a label.
func fixedKey(t *testing.T, label string) ([]byte, hpke.PrivateKey) {
	t.Helper()
	sum := sha256.Sum256([]byte(label))
	key, err := hpke.DHKEM(ecdh.X25519()).NewPrivateKey(sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return sum[:], key
}

func encode(t *testing.T, m Message) []byte {
	t.Helper()
	data, err := EncodeMessage(m)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func seqBytes(seq uint64) []byte { return binary.BigEndian.AppendUint64(nil, seq) }

func kindName(kind byte) string {
	if kind == KindAudio {
		return "audio"
	}
	return "control"
}

// generateVectors runs a full client/server exchange with fixed static keys and
// a seeded global random source, so the ephemeral keys (and every byte) are
// reproducible.
func generateVectors(t *testing.T) vectors {
	cryptotest.SetGlobalRandom(t, 20260927)
	serverRaw, serverKey := fixedKey(t, "localflow test server key v1")
	replyRaw, replyKey := fixedKey(t, "localflow test reply key v1")
	replyPublic := replyKey.PublicKey().Bytes()
	hello := []byte(`{"schema_version":1,"type":"hello","reply_key":"` + b64(replyPublic) +
		`","purpose":"session","access_token":"lfa_` + b64(bytes.Repeat([]byte{0x5a}, 32)) + `"}`)
	if _, err := DecodeHello(hello); err != nil {
		t.Fatal(err)
	}

	client, err := NewClient(serverKey.PublicKey().Bytes(), replyKey)
	if err != nil {
		t.Fatal(err)
	}
	helloFrame, err := client.Hello(hello)
	if err != nil {
		t.Fatal(err)
	}
	server, opened, err := OpenHello(serverKey, helloFrame)
	if err != nil || !bytes.Equal(opened, hello) {
		t.Fatal("hello did not open", err)
	}
	if err := server.Accept(replyPublic); err != nil {
		t.Fatal(err)
	}

	var v vectors
	v.Description = "Test-only HPKE vectors for LocalFlow remote channel v1 (contracts/remote-channel.md). The keys are derived from public labels and protect nothing. Regenerate from server/ with: go test ./internal/remote -run TestHPKEVectors -update"
	v.Encoding = "hex"
	v.Suite = "DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305"
	v.Mode = "base"
	v.KEMID, v.KDFID, v.AEADID = 0x0020, 0x0001, 0x0003
	v.InfoText = ChannelInfo
	v.Info = hex.EncodeToString([]byte(ChannelInfo))
	v.ServerPrivateKey = hex.EncodeToString(serverRaw)
	v.ServerPublicKey = hex.EncodeToString(serverKey.PublicKey().Bytes())
	v.ReplyPrivateKey = hex.EncodeToString(replyRaw)
	v.ReplyPublicKey = hex.EncodeToString(replyPublic)
	v.Hello.Enc = hex.EncodeToString(helloFrame[4 : 4+encLength])
	v.Hello.AAD = hex.EncodeToString(append([]byte(HelloMagic), seqBytes(0)...))
	v.Hello.Plaintext = hex.EncodeToString(hello)
	v.Hello.Frame = hex.EncodeToString(helloFrame)
	v.Exports.S2CInfoLabel = s2cInfoLabel
	v.Exports.S2CInfo = hex.EncodeToString(server.s2cInfo)
	v.Exports.BindingLabel = bindingLabel
	v.Exports.Binding = hex.EncodeToString(server.Binding())

	ready := Frame{KindControl, encode(t, Ready{})}
	first, err := server.Seal(ready)
	if err != nil {
		t.Fatal(err)
	}
	v.ServerFirst.Enc = hex.EncodeToString(first[:encLength])
	v.ServerFirst.Kind = "control"
	v.ServerFirst.AAD = hex.EncodeToString(seqBytes(0))
	v.ServerFirst.Plaintext = hex.EncodeToString(ready.plaintext())
	v.ServerFirst.Frame = hex.EncodeToString(first)
	if got, err := client.Open(first); err != nil || !bytes.Equal(got.Payload, ready.Payload) {
		t.Fatal("first server frame did not open", err)
	}

	audio := make([]byte, 0, 16)
	for _, sample := range []float32{0, 0.5, -0.5, 1} {
		audio = binary.LittleEndian.AppendUint32(audio, math.Float32bits(sample))
	}
	c2s := []Frame{
		{KindControl, encode(t, DictationStart{Op: 1, Format: AudioFormat, SampleRate: SampleRate})},
		{KindAudio, audio},
		{KindControl, encode(t, DictationEnd{Op: 1, TotalSamples: 4})},
	}
	for i, frame := range c2s {
		sealed, err := client.Seal(frame)
		if err != nil {
			t.Fatal(err)
		}
		if got, err := server.Open(sealed); err != nil || got.Kind != frame.Kind || !bytes.Equal(got.Payload, frame.Payload) {
			t.Fatal("c2s frame did not open", err)
		}
		seq := uint64(i + 1)
		v.C2S = append(v.C2S, vectorFrame{seq, kindName(frame.Kind), hex.EncodeToString(seqBytes(seq)), hex.EncodeToString(frame.plaintext()), hex.EncodeToString(sealed)})
	}
	model := ModelIdentity{Engine: "FluidAudio", ModelID: "FluidInference/parakeet-tdt-0.6b-v3-coreml", ModelRevision: "test", ManifestHash: "test", SDK: "0.15.7", WorkerBuild: "test"}
	s2c := []Frame{
		{KindControl, encode(t, DictationAccepted{Op: 1, WindowSamples: WindowSamples, Model: model})},
		{KindControl, encode(t, WindowResult{Op: 1, Index: 0, SampleStart: 0, SampleCount: 4, Text: "", Tokens: []Token{}, BoostHints: []BoostHint{}, RecognitionMS: 5})},
		{KindControl, encode(t, DictationComplete{Op: 1, Windows: 1})},
	}
	for i, frame := range s2c {
		sealed, err := server.Seal(frame)
		if err != nil {
			t.Fatal(err)
		}
		if got, err := client.Open(sealed); err != nil || !bytes.Equal(got.Payload, frame.Payload) {
			t.Fatal("s2c frame did not open", err)
		}
		seq := uint64(i + 1)
		v.S2C = append(v.S2C, vectorFrame{seq, kindName(frame.Kind), hex.EncodeToString(seqBytes(seq)), hex.EncodeToString(frame.plaintext()), hex.EncodeToString(sealed)})
	}
	return v
}

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// TestHPKEVectors checks that the committed vectors reproduce byte for byte,
// then verifies them the way the CryptoKit test does: as the server recipient
// of the hello and c2s frames, and as the client recipient of every s2c frame,
// using crypto/hpke directly rather than Channel.
func TestHPKEVectors(t *testing.T) {
	generated := generateVectors(t)
	encoded, err := json.MarshalIndent(generated, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	encoded = append(encoded, '\n')
	if *update {
		if err := os.WriteFile(vectorsPath, encoded, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	committed, err := os.ReadFile(vectorsPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(committed, encoded) {
		t.Fatal("hpke-vectors.json does not reproduce; if the Go toolchain changed how it draws randomness, regenerate with -update and rerun the Swift RemoteChannelTests")
	}
	var v vectors
	if err := json.Unmarshal(committed, &v); err != nil {
		t.Fatal(err)
	}

	kem := hpke.DHKEM(ecdh.X25519())
	serverKey, err := kem.NewPrivateKey(unhex(t, v.ServerPrivateKey))
	if err != nil || !bytes.Equal(serverKey.PublicKey().Bytes(), unhex(t, v.ServerPublicKey)) {
		t.Fatal("server key pair", err)
	}
	helloFrame := unhex(t, v.Hello.Frame)
	if string(helloFrame[:4]) != "LFR1" || !bytes.Equal(helloFrame[4:36], unhex(t, v.Hello.Enc)) || !bytes.Equal(helloFrame[36:44], make([]byte, 8)) {
		t.Fatal("hello layout")
	}
	recipient, err := hpke.NewRecipient(unhex(t, v.Hello.Enc), serverKey, hpke.HKDFSHA256(), hpke.ChaCha20Poly1305(), unhex(t, v.Info))
	if err != nil {
		t.Fatal(err)
	}
	hello, err := recipient.Open(unhex(t, v.Hello.AAD), helloFrame[44:])
	if err != nil || !bytes.Equal(hello, unhex(t, v.Hello.Plaintext)) {
		t.Fatal("hello open", err)
	}
	s2cInfo, _ := recipient.Export(v.Exports.S2CInfoLabel, 32)
	binding, _ := recipient.Export(v.Exports.BindingLabel, 32)
	if !bytes.Equal(s2cInfo, unhex(t, v.Exports.S2CInfo)) || !bytes.Equal(binding, unhex(t, v.Exports.Binding)) {
		t.Fatal("exports")
	}
	for _, frame := range v.C2S {
		sealed := unhex(t, frame.Frame)
		if !bytes.Equal(sealed[:8], unhex(t, frame.AAD)) || binary.BigEndian.Uint64(sealed[:8]) != frame.Seq {
			t.Fatal("c2s seq prefix", frame.Seq)
		}
		plaintext, err := recipient.Open(sealed[:8], sealed[8:])
		if err != nil || !bytes.Equal(plaintext, unhex(t, frame.Plaintext)) {
			t.Fatal("c2s open", frame.Seq, err)
		}
	}

	replyKey, err := kem.NewPrivateKey(unhex(t, v.ReplyPrivateKey))
	if err != nil || !bytes.Equal(replyKey.PublicKey().Bytes(), unhex(t, v.ReplyPublicKey)) {
		t.Fatal("reply key pair", err)
	}
	first := unhex(t, v.ServerFirst.Frame)
	if !bytes.Equal(first[:32], unhex(t, v.ServerFirst.Enc)) || !bytes.Equal(first[32:40], make([]byte, 8)) {
		t.Fatal("server first layout")
	}
	clientRecipient, err := hpke.NewRecipient(first[:32], replyKey, hpke.HKDFSHA256(), hpke.ChaCha20Poly1305(), s2cInfo)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := clientRecipient.Open(first[32:40], first[40:])
	if err != nil || !bytes.Equal(plaintext, unhex(t, v.ServerFirst.Plaintext)) || plaintext[0] != KindControl {
		t.Fatal("server first open", err)
	}
	kinds := map[string]bool{}
	for _, frame := range append(append([]vectorFrame{}, v.C2S...), v.S2C...) {
		kinds[frame.Kind] = true
	}
	for _, frame := range v.S2C {
		sealed := unhex(t, frame.Frame)
		plaintext, err := clientRecipient.Open(sealed[:8], sealed[8:])
		if err != nil || !bytes.Equal(plaintext, unhex(t, frame.Plaintext)) {
			t.Fatal("s2c open", frame.Seq, err)
		}
	}
	if !kinds["audio"] || !kinds["control"] || len(v.C2S) != 3 || len(v.S2C) != 3 {
		t.Fatal("vectors must hold 3 frames each way with audio and control")
	}
}
