package remote

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/hpke"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func newKey(t *testing.T) hpke.PrivateKey {
	t.Helper()
	key, err := hpke.DHKEM(ecdh.X25519()).GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func helloJSON(replyKey []byte) []byte {
	return []byte(`{"schema_version":1,"type":"hello","reply_key":"` + b64(replyKey) + `","purpose":"refresh"}`)
}

// pair returns an established client and server channel: the hello has been
// opened and the server's first frame (ready) delivered.
func pair(t *testing.T) (client, server *Channel) {
	t.Helper()
	serverKey, replyKey := newKey(t), newKey(t)
	client, err := NewClient(serverKey.PublicKey().Bytes(), replyKey)
	if err != nil {
		t.Fatal(err)
	}
	hello, err := client.Hello(helloJSON(replyKey.PublicKey().Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	server, plaintext, err := OpenHello(serverKey, hello)
	if err != nil || !bytes.Equal(plaintext, helloJSON(replyKey.PublicKey().Bytes())) {
		t.Fatal(err)
	}
	if err := server.Accept(replyKey.PublicKey().Bytes()); err != nil {
		t.Fatal(err)
	}
	first, err := server.Seal(Frame{KindControl, []byte(`{"schema_version":1,"type":"ready"}`)})
	if err != nil {
		t.Fatal(err)
	}
	if frame, err := client.Open(first); err != nil || frame.Kind != KindControl {
		t.Fatal(err)
	}
	return client, server
}

func seal(t *testing.T, c *Channel, payload string) []byte {
	t.Helper()
	sealed, err := c.Seal(Frame{KindControl, []byte(payload)})
	if err != nil {
		t.Fatal(err)
	}
	return sealed
}

func TestChannelRoundTrip(t *testing.T) {
	client, server := pair(t)
	if !bytes.Equal(client.Binding(), server.Binding()) || len(client.Binding()) != 32 {
		t.Fatal("binding differs")
	}
	other, _ := pair(t)
	if bytes.Equal(other.Binding(), client.Binding()) {
		t.Fatal("binding must be per channel")
	}
	for i := range 3 {
		frame, err := server.Open(seal(t, client, `{"n":1}`))
		if err != nil || string(frame.Payload) != `{"n":1}` {
			t.Fatal(i, err)
		}
		frame, err = client.Open(seal(t, server, `{"n":2}`))
		if err != nil || string(frame.Payload) != `{"n":2}` {
			t.Fatal(i, err)
		}
	}
	samples := make([]byte, MaxAudioSamples*4)
	sealed, err := client.Seal(Frame{KindAudio, samples})
	if err != nil || len(sealed) > MaxBinaryMessage {
		t.Fatal(len(sealed), err)
	}
	if frame, err := server.Open(sealed); err != nil || frame.Kind != KindAudio || len(frame.Payload) != len(samples) {
		t.Fatal(err)
	}
}

// Replayed, reordered, dropped, duplicated, truncated and altered frames fail
// the channel for good: the error is fatal and even the correct next frame is
// refused afterwards.
func TestChannelSequenceFailuresAreFatal(t *testing.T) {
	cases := map[string]func(t *testing.T, client, server *Channel) (bad []byte, next []byte){
		"replayed": func(t *testing.T, client, server *Channel) ([]byte, []byte) {
			first := seal(t, client, "{}")
			if _, err := server.Open(first); err != nil {
				t.Fatal(err)
			}
			return first, seal(t, client, "{}")
		},
		"reordered": func(t *testing.T, client, server *Channel) ([]byte, []byte) {
			first, second := seal(t, client, "{}"), seal(t, client, "{}")
			return second, first
		},
		"dropped": func(t *testing.T, client, server *Channel) ([]byte, []byte) {
			seal(t, client, "{}")
			second := seal(t, client, "{}")
			return second, seal(t, client, "{}")
		},
		"duplicated": func(t *testing.T, client, server *Channel) ([]byte, []byte) {
			first := seal(t, client, "{}")
			if _, err := server.Open(first); err != nil {
				t.Fatal(err)
			}
			return first, first
		},
		"truncated": func(t *testing.T, client, server *Channel) ([]byte, []byte) {
			first := seal(t, client, "{}")
			return first[:len(first)-1], first
		},
		"header only": func(t *testing.T, client, server *Channel) ([]byte, []byte) {
			first := seal(t, client, "{}")
			return first[:5], first
		},
		"altered ciphertext": func(t *testing.T, client, server *Channel) ([]byte, []byte) {
			first := seal(t, client, "{}")
			bad := bytes.Clone(first)
			bad[len(bad)-1] ^= 1
			return bad, first
		},
		"seq rewritten to match": func(t *testing.T, client, server *Channel) ([]byte, []byte) {
			seal(t, client, "{}")
			second := bytes.Clone(seal(t, client, "{}"))
			second[7] = 1 // claims seq 1, sealed as seq 2
			return second, second
		},
		"over 70,000 bytes": func(t *testing.T, client, server *Channel) ([]byte, []byte) {
			return make([]byte, MaxBinaryMessage+1), seal(t, client, "{}")
		},
	}
	for name, build := range cases {
		t.Run(name, func(t *testing.T) {
			client, server := pair(t)
			bad, next := build(t, client, server)
			if _, err := server.Open(bad); !errors.Is(err, ErrChannelFailed) {
				t.Fatalf("bad frame: %v", err)
			}
			if _, err := server.Open(next); !errors.Is(err, ErrChannelFailed) {
				t.Fatalf("channel must stay failed: %v", err)
			}
			if _, err := server.Seal(Frame{KindControl, []byte("{}")}); !errors.Is(err, ErrChannelFailed) {
				t.Fatalf("failed channel must not seal: %v", err)
			}
		})
	}
}

// A server frame sealed by anyone without the client-to-server context (here
// a second server that saw the same reply key) does not open.
func TestClientRefusesInjectedServerFrames(t *testing.T) {
	client, _ := pair(t)
	_, impostor := pair(t)
	if _, err := client.Open(seal(t, impostor, "{}")); !errors.Is(err, ErrChannelFailed) {
		t.Fatal(err)
	}
	client, server := pair(t)
	first, second := seal(t, server, "{}"), seal(t, server, "{}")
	if _, err := client.Open(second); !errors.Is(err, ErrChannelFailed) {
		t.Fatal("reordered server frame opened")
	}
	if _, err := client.Open(first); !errors.Is(err, ErrChannelFailed) {
		t.Fatal("client channel must stay failed")
	}
}

func TestOpenHelloRefusals(t *testing.T) {
	serverKey, otherKey, replyKey := newKey(t), newKey(t), newKey(t)
	client, _ := NewClient(otherKey.PublicKey().Bytes(), replyKey)
	toOther, _ := client.Hello(helloJSON(replyKey.PublicKey().Bytes()))
	client, _ = NewClient(serverKey.PublicKey().Bytes(), replyKey)
	good, _ := client.Hello(helloJSON(replyKey.PublicKey().Bytes()))
	badMagic := bytes.Clone(good)
	badMagic[0] = 'X'
	badSeq := bytes.Clone(good)
	badSeq[4+32+7] = 1
	for name, message := range map[string][]byte{
		"different server key": toOther,
		"wrong magic":          badMagic,
		"seq not zero":         badSeq,
		"truncated":            good[:len(good)-1],
		"header only":          good[:44],
		"empty":                nil,
		"over 70,000 bytes":    append(bytes.Clone(good), make([]byte, MaxBinaryMessage)...),
	} {
		if _, _, err := OpenHello(serverKey, message); !errors.Is(err, ErrHelloRefused) {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, _, err := OpenHello(serverKey, good); err != nil {
		t.Fatal(err)
	}
	if err := (&Channel{}).Accept(make([]byte, 31)); err == nil {
		t.Fatal("short reply key accepted")
	}
}

// Authentic frames with a bad payload are refused with a channel error code:
// audio must be 1…16,000 f32le samples, control at most 65,536 bytes, the kind
// known, and audio only ever travels from client to server.
func TestFramePayloadRules(t *testing.T) {
	cases := []struct {
		name      string
		plaintext []byte
		code      ErrorCode
	}{
		{"empty plaintext", nil, CodeInvalidMessage},
		{"unknown kind", []byte{0x02, '{', '}'}, CodeInvalidMessage},
		{"empty audio", []byte{KindAudio}, CodeInvalidMessage},
		{"audio not a multiple of 4", append([]byte{KindAudio}, make([]byte, 6)...), CodeInvalidMessage},
		{"16,001 samples", append([]byte{KindAudio}, make([]byte, (MaxAudioSamples+1)*4)...), CodeLimitExceeded},
		{"control over 65,536 bytes", append([]byte{KindControl}, make([]byte, MaxControlBytes+1)...), CodeLimitExceeded},
	}
	for _, tc := range cases {
		client, server := pair(t)
		sealed, err := client.sealPlaintext(tc.plaintext)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := server.Open(sealed); CodeOf(err) != tc.code || errors.Is(err, ErrChannelFailed) {
			t.Errorf("%s: %v", tc.name, err)
		}
		// The frame was authentic, so the counters stay in step.
		if _, err := server.Open(seal(t, client, "{}")); err != nil {
			t.Errorf("%s: next frame: %v", tc.name, err)
		}
	}
	for _, samples := range []int{1, MaxAudioSamples} {
		client, server := pair(t)
		sealed, _ := client.Seal(Frame{KindAudio, make([]byte, samples*4)})
		if _, err := server.Open(sealed); err != nil {
			t.Errorf("%d samples: %v", samples, err)
		}
	}
	client, server := pair(t)
	sealed, _ := server.sealPlaintext(append([]byte{KindAudio}, make([]byte, 8)...))
	if _, err := client.Open(sealed); CodeOf(err) != CodeInvalidMessage {
		t.Fatalf("audio from the server: %v", err)
	}
	if _, err := server.Seal(Frame{KindAudio, make([]byte, 8)}); err == nil {
		t.Fatal("server sealed audio")
	}
	if _, err := client.Seal(Frame{KindControl, make([]byte, MaxControlBytes+1)}); err == nil {
		t.Fatal("oversized control sealed")
	}
}

// channelServer runs the socket adapter the way the listener does: read and
// open the hello, answer ready, then open frames until something fails.
func channelServer(t *testing.T, key hpke.PrivateKey) (string, chan error) {
	t.Helper()
	results := make(chan error, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			results <- err
			return
		}
		ctx := r.Context()
		s := newSocket(ws)
		channel, plaintext, err := acceptHello(ctx, s, key)
		if err != nil {
			results <- err
			return
		}
		hello, err := DecodeHello(plaintext)
		if err != nil {
			results <- err
			return
		}
		if err := channel.Accept(hello.ReplyKey); err != nil {
			results <- err
			return
		}
		ready, _ := channel.Seal(Frame{KindControl, []byte(`{"schema_version":1,"type":"ready"}`)})
		if err := s.write(ctx, ready); err != nil {
			results <- err
			return
		}
		for {
			message, err := s.read(ctx)
			if err != nil {
				results <- err
				return
			}
			if _, err := channel.Open(message); err != nil {
				s.close(websocket.StatusPolicyViolation)
				results <- err
				return
			}
		}
	}))
	t.Cleanup(server.Close)
	return "ws" + strings.TrimPrefix(server.URL, "http"), results
}

func dial(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	ws.SetReadLimit(MaxBinaryMessage)
	t.Cleanup(func() { ws.CloseNow() })
	return ws
}

// connect dials, sends a hello to serverKey and returns the client channel.
func connect(t *testing.T, url string, serverKey []byte) (*websocket.Conn, *Channel) {
	t.Helper()
	ws := dial(t, url)
	replyKey := newKey(t)
	client, err := NewClient(serverKey, replyKey)
	if err != nil {
		t.Fatal(err)
	}
	hello, _ := client.Hello(helloJSON(replyKey.PublicKey().Bytes()))
	if err := ws.Write(context.Background(), websocket.MessageBinary, hello); err != nil {
		t.Fatal(err)
	}
	return ws, client
}

func readTimeout(ws *websocket.Conn) (websocket.MessageType, []byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return ws.Read(ctx)
}

func TestSocketHelloToWrongKeyCloses4001(t *testing.T) {
	serverKey := newKey(t)
	url, results := channelServer(t, serverKey)
	ws, _ := connect(t, url, newKey(t).PublicKey().Bytes())
	_, data, err := readTimeout(ws)
	if websocket.CloseStatus(err) != CloseHelloRefused || data != nil {
		t.Fatalf("status %d data %x err %v", websocket.CloseStatus(err), data, err)
	}
	if err := <-results; !errors.Is(err, ErrHelloRefused) {
		t.Fatal(err)
	}
}

func TestSocketClosesOnTextAndOversize(t *testing.T) {
	serverKey := newKey(t)
	for name, tc := range map[string]struct {
		afterHello bool
		kind       websocket.MessageType
		size       int
		status     websocket.StatusCode
	}{
		"text before hello":   {false, websocket.MessageText, 10, websocket.StatusUnsupportedData},
		"text after hello":    {true, websocket.MessageText, 10, websocket.StatusUnsupportedData},
		"70,001 bytes":        {true, websocket.MessageBinary, MaxBinaryMessage + 1, websocket.StatusMessageTooBig},
		"70,001 bytes hello":  {false, websocket.MessageBinary, MaxBinaryMessage + 1, websocket.StatusMessageTooBig},
		"70,000 bytes opened": {true, websocket.MessageBinary, MaxBinaryMessage, websocket.StatusPolicyViolation},
	} {
		t.Run(name, func(t *testing.T) {
			url, results := channelServer(t, serverKey)
			var ws *websocket.Conn
			if tc.afterHello {
				var client *Channel
				ws, client = connect(t, url, serverKey.PublicKey().Bytes())
				_, first, err := readTimeout(ws)
				if err != nil {
					t.Fatal(err)
				}
				if _, err := client.Open(first); err != nil {
					t.Fatal(err)
				}
			} else {
				ws = dial(t, url)
			}
			// The server may close before the whole message is written.
			_ = ws.Write(context.Background(), tc.kind, make([]byte, tc.size))
			_, data, err := readTimeout(ws)
			if websocket.CloseStatus(err) != tc.status || data != nil {
				t.Fatalf("status %d, want %d (%v)", websocket.CloseStatus(err), tc.status, err)
			}
			if err := <-results; err == nil {
				t.Fatal("server kept the channel open")
			}
		})
	}
}
