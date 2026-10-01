package remote

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const messagesDir = "../../../fixtures/remote/messages"

// decodeFixture decodes one example by its file name: identity*, hello* or a
// control message.
func decodeFixture(name string, data []byte) (any, error) {
	switch {
	case strings.HasPrefix(name, "identity"):
		return DecodeIdentity(data)
	case strings.HasPrefix(name, "hello"):
		return DecodeHello(data)
	default:
		return DecodeMessage(data)
	}
}

// Every valid example decodes and survives an encode/decode round trip; every
// invalid example is refused with the code its name states (reason
// unsupported-version or limit-exceeded, invalid_message otherwise).
func TestMessageFixtures(t *testing.T) {
	for _, kind := range []string{"valid", "invalid"} {
		paths, err := filepath.Glob(filepath.Join(messagesDir, kind, "*.json"))
		if err != nil || len(paths) == 0 {
			t.Fatalf("no %s fixtures: %v", kind, err)
		}
		for _, path := range paths {
			name := strings.TrimSuffix(filepath.Base(path), ".json")
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			decoded, err := decodeFixture(name, data)
			if kind == "invalid" {
				want := CodeInvalidMessage
				switch {
				case strings.HasSuffix(name, "-unsupported-version"):
					want = CodeUnsupportedVersion
				case strings.HasSuffix(name, "-limit-exceeded"):
					want = CodeLimitExceeded
				}
				if CodeOf(err) != want {
					t.Errorf("%s: code %q, want %q (%v)", name, CodeOf(err), want, err)
				}
				continue
			}
			if err != nil {
				t.Errorf("%s: %v", name, err)
				continue
			}
			message, ok := decoded.(Message)
			if !ok {
				continue
			}
			encoded, err := EncodeMessage(message)
			if err != nil {
				t.Errorf("%s: encode: %v", name, err)
				continue
			}
			again, err := DecodeMessage(encoded)
			if err != nil || !reflect.DeepEqual(again, message) {
				t.Errorf("%s: round trip %+v != %+v (%v)", name, again, message, err)
			}
		}
	}
}

func TestEveryMessageTypeHasFixtures(t *testing.T) {
	for _, messageType := range MessageTypes {
		for _, kind := range []string{"valid", "invalid"} {
			matches, _ := filepath.Glob(filepath.Join(messagesDir, kind, messageType+"*.json"))
			if len(matches) == 0 {
				t.Errorf("no %s fixture for %s", kind, messageType)
			}
		}
	}
	if len(MessageTypes) != 26 {
		t.Fatalf("%d message types", len(MessageTypes))
	}
}

func loadObject(t *testing.T, name string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(messagesDir, "valid", name+".json"))
	if err != nil {
		t.Fatal(err)
	}
	var object map[string]any
	if err := json.Unmarshal(data, &object); err != nil {
		t.Fatal(err)
	}
	return object
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func TestDecodeMessageRejections(t *testing.T) {
	p256 := "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
	terms := func(n int, canonical string) []any {
		out := make([]any, n)
		for i := range out {
			out[i] = map[string]any{"entry_id": "e", "canonical": canonical}
		}
		return out
	}
	governed := func(n int, spelling string) []any {
		out := make([]any, n)
		for i := range out {
			out[i] = spelling
		}
		return out
	}
	cases := []struct {
		name    string
		fixture string
		mutate  func(m map[string]any)
		code    ErrorCode
	}{
		{"unknown schema_version", "dictation_end", func(m map[string]any) { m["schema_version"] = 2 }, CodeUnsupportedVersion},
		{"unknown schema_version and type", "dictation_end", func(m map[string]any) { m["schema_version"] = 9; m["type"] = "x" }, CodeUnsupportedVersion},
		{"missing schema_version", "dictation_end", func(m map[string]any) { delete(m, "schema_version") }, CodeInvalidMessage},
		{"string schema_version", "dictation_end", func(m map[string]any) { m["schema_version"] = "1" }, CodeInvalidMessage},
		{"unknown type", "dictation_end", func(m map[string]any) { m["type"] = "dictation_pause" }, CodeInvalidMessage},
		{"hello as message", "dictation_end", func(m map[string]any) { m["type"] = "hello" }, CodeInvalidMessage},
		{"missing type", "dictation_end", func(m map[string]any) { delete(m, "type") }, CodeInvalidMessage},
		{"missing field", "dictation_end", func(m map[string]any) { delete(m, "total_samples") }, CodeInvalidMessage},
		{"missing op", "dictation_end", func(m map[string]any) { delete(m, "op") }, CodeInvalidMessage},
		{"null field", "dictation_end", func(m map[string]any) { m["total_samples"] = nil }, CodeInvalidMessage},
		{"unknown field", "dictation_end", func(m map[string]any) { m["user_id"] = 3 }, CodeInvalidMessage},
		{"string op", "dictation_end", func(m map[string]any) { m["op"] = "1" }, CodeInvalidMessage},
		{"fractional op", "dictation_end", func(m map[string]any) { m["op"] = 1.5 }, CodeInvalidMessage},
		{"zero op", "dictation_end", func(m map[string]any) { m["op"] = 0 }, CodeInvalidMessage},
		{"negative op", "dictation_end", func(m map[string]any) { m["op"] = -4 }, CodeInvalidMessage},
		{"op over 2^31-1", "dictation_end", func(m map[string]any) { m["op"] = 2147483648 }, CodeInvalidMessage},
		{"zero op on error", "error", func(m map[string]any) { m["op"] = 0 }, CodeInvalidMessage},
		{"format", "dictation_start", func(m map[string]any) { m["format"] = "s16le" }, CodeInvalidMessage},
		{"sample rate", "dictation_start", func(m map[string]any) { m["sample_rate"] = 48000 }, CodeInvalidMessage},
		{"257 terms", "dictation_start", func(m map[string]any) {
			m["boost"] = map[string]any{"terms": terms(257, "T"), "governed": []any{}}
		}, CodeInvalidMessage},
		{"1,025 governed", "dictation_start", func(m map[string]any) {
			m["boost"] = map[string]any{"terms": []any{}, "governed": governed(1025, "g")}
		}, CodeInvalidMessage},
		{"term over 128 bytes, under 128 characters", "dictation_start", func(m map[string]any) {
			m["boost"] = map[string]any{"terms": terms(1, strings.Repeat("ž", 65)), "governed": []any{}}
		}, CodeInvalidMessage},
		{"governed over 128 bytes", "dictation_start", func(m map[string]any) {
			m["boost"] = map[string]any{"terms": []any{}, "governed": governed(1, strings.Repeat("a", 129))}
		}, CodeInvalidMessage},
		{"empty term", "dictation_start", func(m map[string]any) {
			m["boost"] = map[string]any{"terms": terms(1, ""), "governed": []any{}}
		}, CodeInvalidMessage},
		{"boost without governed", "dictation_start", func(m map[string]any) {
			m["boost"] = map[string]any{"terms": terms(1, "T")}
		}, CodeInvalidMessage},
		{"boost extra field", "dictation_start", func(m map[string]any) {
			m["boost"] = map[string]any{"terms": []any{}, "governed": []any{}, "user": 2}
		}, CodeInvalidMessage},
		{"device name over 64 bytes", "enroll", func(m map[string]any) { m["device_name"] = strings.Repeat("é", 33) }, CodeInvalidMessage},
		{"device name only control characters", "enroll", func(m map[string]any) { m["device_name"] = "\u0000\u001b\u007f" }, CodeInvalidMessage},
		{"device key 64 bytes", "enroll", func(m map[string]any) { m["device_key"] = b64(make([]byte, 64)) }, CodeInvalidMessage},
		{"device key compressed prefix", "enroll", func(m map[string]any) {
			key := make([]byte, 65)
			key[0] = 0x02
			m["device_key"] = b64(key)
		}, CodeInvalidMessage},
		{"device key off the curve", "enroll", func(m map[string]any) {
			key := make([]byte, 65)
			key[0] = 0x04
			m["device_key"] = b64(key)
		}, CodeInvalidMessage},
		{"device key padded base64", "enroll", func(m map[string]any) {
			raw, _ := hex.DecodeString(p256)
			m["device_key"] = base64.URLEncoding.EncodeToString(raw)
		}, CodeInvalidMessage},
		{"unknown provider", "enroll", func(m map[string]any) { m["provider"] = "github" }, CodeInvalidMessage},
		{"signature too short", "enroll", func(m map[string]any) { m["signature"] = b64([]byte{1, 2, 3}) }, CodeInvalidMessage},
		{"id token not a JWT", "enroll", func(m map[string]any) { m["id_token"] = "abc" }, CodeInvalidMessage},
		{"refresh token wrong length", "refresh", func(m map[string]any) { m["refresh_token"] = "lfr_abc" }, CodeInvalidMessage},
		{"rewrite request array", "rewrite", func(m map[string]any) { m["request"] = []any{1} }, CodeInvalidMessage},
		{"error message too long", "error", func(m map[string]any) { m["message"] = strings.Repeat("a", 257) }, CodeInvalidMessage},
		{"window token negative time", "window_result", func(m map[string]any) {
			m["tokens"] = []any{map[string]any{"text": "a", "start": -1, "end": 0}}
		}, CodeInvalidMessage},
		{"window index 14", "window_result", func(m map[string]any) { m["index"] = 14 }, CodeInvalidMessage},
	}
	for _, tc := range cases {
		object := loadObject(t, tc.fixture)
		tc.mutate(object)
		_, err := DecodeMessage(mustJSON(t, object))
		if CodeOf(err) != tc.code {
			t.Errorf("%s: code %q, want %q (%v)", tc.name, CodeOf(err), tc.code, err)
		}
	}
}

func TestDecodeMessageFraming(t *testing.T) {
	for name, body := range map[string]string{
		"not an object": `[1]`,
		"trailing data": `{"schema_version":1,"type":"ready"} {}`,
		"not JSON":      `{"schema_version":1,`,
		"invalid UTF-8": "{\"schema_version\":1,\"type\":\"ready\",\"x\":\"\xff\"}",
		"empty":         ``,
	} {
		if _, err := DecodeMessage([]byte(body)); CodeOf(err) != CodeInvalidMessage {
			t.Errorf("%s: %v", name, err)
		}
	}
	// A control message over 65,536 bytes is limit_exceeded before parsing,
	// whatever it contains; exactly 65,536 bytes is parsed.
	pad := func(n int) []byte {
		prefix := `{"schema_version":1,"type":"error","code":"busy","message":"`
		suffix := `"}`
		return []byte(prefix + strings.Repeat("a", n-len(prefix)-len(suffix)) + suffix)
	}
	if _, err := DecodeMessage(pad(MaxControlBytes + 1)); CodeOf(err) != CodeLimitExceeded {
		t.Fatal(err)
	}
	if _, err := DecodeMessage(pad(MaxControlBytes)); CodeOf(err) != CodeInvalidMessage {
		t.Fatalf("65,536 bytes must be parsed (and fail the message bound): %v", err)
	}
}

func TestDeviceNameControlCharactersRemoved(t *testing.T) {
	object := loadObject(t, "enroll")
	object["device_name"] = "Oliver\u0000's\u001b Mac‮\u007f"
	decoded, err := DecodeMessage(mustJSON(t, object))
	if err != nil {
		t.Fatal(err)
	}
	if name := decoded.(Enroll).DeviceName; name != "Oliver's Mac" {
		t.Fatalf("name %q", name)
	}
	// 64 bytes of text survives when padded with control characters.
	object["device_name"] = strings.Repeat("a", 64) + "\u0007\u0007"
	if _, err := DecodeMessage(mustJSON(t, object)); err != nil {
		t.Fatal(err)
	}
}

func TestDecodeHello(t *testing.T) {
	object := loadObject(t, "hello-session")
	hello, err := DecodeHello(mustJSON(t, object))
	if err != nil || hello.Purpose != PurposeSession || len(hello.ReplyKey) != KeyBytes || !strings.HasPrefix(hello.AccessToken, "lfa_") {
		t.Fatal(hello, err)
	}
	for name, mutate := range map[string]func(map[string]any){
		"unknown purpose":   func(m map[string]any) { m["purpose"] = "admin" },
		"wrong type":        func(m map[string]any) { m["type"] = "ready" },
		"extra field":       func(m map[string]any) { m["user_id"] = 1 },
		"token missing":     func(m map[string]any) { delete(m, "access_token") },
		"reply key 33":      func(m map[string]any) { m["reply_key"] = b64(make([]byte, 33)) },
		"reply key missing": func(m map[string]any) { delete(m, "reply_key") },
	} {
		object := loadObject(t, "hello-session")
		mutate(object)
		if _, err := DecodeHello(mustJSON(t, object)); CodeOf(err) != CodeInvalidMessage {
			t.Errorf("%s: %v", name, err)
		}
	}
	// A present but malformed access token is unauthorized, not a schema error.
	for _, token := range []string{"lfr_" + strings.Repeat("A", 43), "lfa_short", "lfa_" + strings.Repeat("*", 43)} {
		object := loadObject(t, "hello-session")
		object["access_token"] = token
		if hello, err := DecodeHello(mustJSON(t, object)); CodeOf(err) != CodeUnauthorized || len(hello.ReplyKey) != KeyBytes {
			t.Errorf("%s: %v", token, err)
		}
	}
	object = loadObject(t, "hello-enroll")
	object["schema_version"] = 3
	hello, err = DecodeHello(mustJSON(t, object))
	if CodeOf(err) != CodeUnsupportedVersion {
		t.Fatal(err)
	}
	// The reply key is still returned so the server can seal the error.
	if len(hello.ReplyKey) != KeyBytes {
		t.Fatal("reply key not returned with unsupported_version")
	}
}

func TestEncodeMessage(t *testing.T) {
	data, err := EncodeMessage(NewError(3, CodeBusy))
	if err != nil || string(data) != `{"schema_version":1,"type":"error","op":3,"code":"busy","message":"The server is busy."}` {
		t.Fatalf("%s %v", data, err)
	}
	data, err = EncodeMessage(NewError(0, CodeUnauthorized))
	if err != nil || strings.Contains(string(data), `"op"`) {
		t.Fatalf("hello errors carry no op: %s %v", data, err)
	}
	data, err = EncodeMessage(Ready{})
	if err != nil || string(data) != `{"schema_version":1,"type":"ready"}` {
		t.Fatalf("%s %v", data, err)
	}
	// The server never emits a message its own decoder would refuse.
	if _, err := EncodeMessage(Progress{Op: 1, State: "running"}); err == nil {
		t.Fatal("invalid message encoded")
	}
}

func TestErrorCodes(t *testing.T) {
	if len(ErrorCodes) != 11 {
		t.Fatal(len(ErrorCodes))
	}
	seen := map[string]bool{}
	for _, code := range ErrorCodes {
		message := code.Message()
		if message == "" || !strings.HasSuffix(message, ".") || strings.Count(message, ".") != 1 || seen[message] {
			t.Errorf("%s: %q", code, message)
		}
		seen[message] = true
	}
	if CodeOf(nil) != "" || CodeOf(errors.New("x")) != CodeInternal {
		t.Fatal("CodeOf")
	}
	if ErrorCode("teapot").Message() != CodeInternal.Message() {
		t.Fatal("unknown code message")
	}
}

// Feature 018 T005: the new messages' per-kind bounds. Sample counts and
// formats outside the contract are invalid_message; fragments over their
// byte bounds are limit_exceeded.
func TestFeature018Rejections(t *testing.T) {
	cases := []struct {
		name    string
		fixture string
		mutate  func(m map[string]any)
		code    ErrorCode
	}{
		{"live 0 samples", "live_window", func(m map[string]any) { m["sample_count"] = 0 }, CodeInvalidMessage},
		{"live 96,001 samples", "live_window", func(m map[string]any) { m["sample_count"] = 96001 }, CodeInvalidMessage},
		{"live f32le", "live_window", func(m map[string]any) { m["format"] = "f32le" }, CodeInvalidMessage},
		{"live language", "live_window", func(m map[string]any) { m["language"] = "Slovak" }, CodeInvalidMessage},
		{"transcribe 0 samples", "meeting_job", func(m map[string]any) { m["sample_count"] = 0 }, CodeInvalidMessage},
		{"transcribe 1,920,001 samples", "meeting_job", func(m map[string]any) { m["sample_count"] = 1920001 }, CodeInvalidMessage},
		{"transcribe f32le", "meeting_job", func(m map[string]any) { m["format"] = "f32le" }, CodeInvalidMessage},
		{"transcribe num_speakers", "meeting_job", func(m map[string]any) { m["num_speakers"] = 2 }, CodeInvalidMessage},
		{"transcribe 257 terms", "meeting_job", func(m map[string]any) {
			terms := make([]any, 257)
			for i := range terms {
				terms[i] = "t"
			}
			m["vocabulary_terms"] = terms
		}, CodeInvalidMessage},
		{"transcribe term over 128 bytes", "meeting_job", func(m map[string]any) { m["vocabulary_terms"] = []any{strings.Repeat("ž", 65)} }, CodeInvalidMessage},
		{"unknown kind", "meeting_job", func(m map[string]any) { m["kind"] = "summarize" }, CodeInvalidMessage},
		{"diarize 9,600,001 samples", "meeting_job-diarize", func(m map[string]any) { m["sample_count"] = 9600001 }, CodeInvalidMessage},
		{"diarize pipeline", "meeting_job-diarize", func(m map[string]any) { m["pipeline"] = "p" }, CodeInvalidMessage},
		{"diarize 0 speakers", "meeting_job-diarize", func(m map[string]any) { m["num_speakers"] = 0 }, CodeInvalidMessage},
		{"embed 47,999 samples", "meeting_job-embed", func(m map[string]any) { m["sample_count"] = 47999 }, CodeInvalidMessage},
		{"embed 320,001 samples", "meeting_job-embed", func(m map[string]any) { m["sample_count"] = 320001 }, CodeInvalidMessage},
		{"embed language", "meeting_job-embed", func(m map[string]any) { m["language"] = "sk" }, CodeInvalidMessage},
		{"analysis_part over 49,152 bytes", "analysis_part", func(m map[string]any) { m["data"] = strings.Repeat("a", MaxAnalysisPartBytes+1) }, CodeLimitExceeded},
		{"analysis_part empty", "analysis_part", func(m map[string]any) { m["data"] = "" }, CodeInvalidMessage},
		{"analysis_part index 64", "analysis_part", func(m map[string]any) { m["index"] = 64 }, CodeInvalidMessage},
		{"analysis over 262,144 bytes", "analysis", func(m map[string]any) { m["bytes"] = MaxAnalysisBytes + 1 }, CodeLimitExceeded},
		{"analysis 0 parts", "analysis", func(m map[string]any) { m["parts"] = 0 }, CodeInvalidMessage},
		{"analysis uppercase sha256", "analysis", func(m map[string]any) { m["sha256"] = strings.ToUpper(m["sha256"].(string)) }, CodeInvalidMessage},
		{"analysis_event_part over 49,152 bytes", "analysis_event_part", func(m map[string]any) { m["data"] = strings.Repeat("a", MaxAnalysisPartBytes+1) }, CodeLimitExceeded},
		{"analysis_event neither form", "analysis_event", func(m map[string]any) { delete(m, "event") }, CodeInvalidMessage},
		{"analysis_event parts without sha256", "analysis_event-parts", func(m map[string]any) { delete(m, "sha256") }, CodeInvalidMessage},
		{"analysis_event event and parts", "analysis_event", func(m map[string]any) { m["parts"] = 2 }, CodeInvalidMessage},
		{"live_result negative token time", "live_result", func(m map[string]any) {
			m["window"].(map[string]any)["tokens"] = []any{map[string]any{"text": "a", "start": -1, "end": 0}}
		}, CodeInvalidMessage},
		{"meeting_progress position -1", "meeting_progress", func(m map[string]any) { m["position"] = -1 }, CodeInvalidMessage},
		{"meeting_result diarize result for embed", "meeting_result-embed", func(m map[string]any) {
			m["result"] = map[string]any{"turns": []any{}, "centroids": []any{}}
		}, CodeInvalidMessage},
		{"meeting_result retry depth 3", "meeting_result", func(m map[string]any) { m["result"].(map[string]any)["retry_depth"] = 3 }, CodeInvalidMessage},
		{"meeting_result turn end before start", "meeting_result-diarize", func(m map[string]any) {
			m["result"].(map[string]any)["turns"] = []any{map[string]any{"cluster": 0, "start": 2.0, "end": 1.0}}
		}, CodeInvalidMessage},
		{"meeting_result empty vector", "meeting_result-embed", func(m map[string]any) { m["result"].(map[string]any)["vector"] = []any{} }, CodeInvalidMessage},
		{"meeting_result model without engine", "meeting_result", func(m map[string]any) { delete(m["model"].(map[string]any), "engine") }, CodeInvalidMessage},
		{"capabilities null ops", "ready-capabilities", func(m map[string]any) { m["capabilities"].(map[string]any)["ops"] = nil }, CodeInvalidMessage},
		{"capabilities duplicate op", "ready-capabilities", func(m map[string]any) {
			m["capabilities"].(map[string]any)["ops"] = []any{"rewrite", "rewrite"}
		}, CodeInvalidMessage},
		{"capabilities voice without dimension", "ready-capabilities", func(m map[string]any) {
			delete(m["capabilities"].(map[string]any)["models"].(map[string]any)["voice"].(map[string]any), "dimension")
		}, CodeInvalidMessage},
	}
	for _, tc := range cases {
		object := loadObject(t, tc.fixture)
		tc.mutate(object)
		_, err := DecodeMessage(mustJSON(t, object))
		if CodeOf(err) != tc.code {
			t.Errorf("%s: code %q, want %q (%v)", tc.name, CodeOf(err), tc.code, err)
		}
	}
	// A Feature 014 ready, without capabilities, still decodes.
	if m, err := DecodeMessage([]byte(`{"schema_version":1,"type":"ready"}`)); err != nil || m.(Ready).Capabilities != nil {
		t.Fatalf("%#v %v", m, err)
	}
	m, err := DecodeMessage(mustJSON(t, loadObject(t, "ready-capabilities")))
	if err != nil || m.(Ready).Capabilities.Models.Voice.Dimension != 256 {
		t.Fatalf("%#v %v", m, err)
	}
	if data, err := EncodeMessage(NewError(4, CodeNotOffered)); err != nil || !strings.Contains(string(data), `"code":"not_offered"`) {
		t.Fatalf("%s %v", data, err)
	}
}
