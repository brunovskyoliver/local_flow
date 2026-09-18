package rewrite

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

const validID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

func validRequestJSON() map[string]any {
	return map[string]any{
		"schema_version": 1, "request_id": validID, "mode": "clean",
		"text": "peter can you move the deployment", "language_hints": []string{}, "stream_deltas": false,
	}
}

func encode(t *testing.T, v any) []byte {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestDecodeRequestAcceptsValidBody(t *testing.T) {
	req, err := DecodeRequest(bytes.NewReader(encode(t, validRequestJSON())))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if req.RequestID != validID || req.Mode != "clean" || req.StreamDeltas {
		t.Fatalf("unexpected request: %+v", req)
	}
	if req.MaxOutputBytes() != 4*len(req.Text) {
		t.Fatalf("output bound = %d", req.MaxOutputBytes())
	}
	big := validRequestJSON()
	big["text"] = strings.Repeat("a", 20000)
	req, err = DecodeRequest(bytes.NewReader(encode(t, big)))
	if err != nil {
		t.Fatalf("20,000 scalars must be accepted: %v", err)
	}
	if req.MaxOutputBytes() != MaxInputBytes {
		t.Fatalf("output bound must cap at 65,536, got %d", req.MaxOutputBytes())
	}
}

func TestDecodeRequestRejections(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(m map[string]any)
		code   ErrorCode
	}{
		{"unknown field", func(m map[string]any) { m["audio"] = "x" }, CodeInvalidRequest},
		{"missing field", func(m map[string]any) { delete(m, "language_hints") }, CodeInvalidRequest},
		{"wrong schema version", func(m map[string]any) { m["schema_version"] = 2 }, CodeUnsupportedVersion},
		{"string schema version", func(m map[string]any) { m["schema_version"] = "1" }, CodeUnsupportedVersion},
		{"invalid uuid", func(m map[string]any) { m["request_id"] = "not-a-uuid" }, CodeInvalidRequest},
		{"numeric request id", func(m map[string]any) { m["request_id"] = 12 }, CodeInvalidRequest},
		{"exact mode", func(m map[string]any) { m["mode"] = "exact" }, CodeInvalidRequest},
		{"unknown mode", func(m map[string]any) { m["mode"] = "shout" }, CodeInvalidRequest},
		{"blank text", func(m map[string]any) { m["text"] = " \n\t" }, CodeInvalidRequest},
		{"numeric text", func(m map[string]any) { m["text"] = 5 }, CodeInvalidRequest},
		{"text over scalars", func(m map[string]any) { m["text"] = strings.Repeat("a", 20001) }, CodeTooLarge},
		{"text over bytes", func(m map[string]any) { m["text"] = strings.Repeat("\U0001F600", 16385) }, CodeTooLarge},
		{"too many hints", func(m map[string]any) { m["language_hints"] = []string{"a", "b", "c", "d", "e"} }, CodeInvalidRequest},
		{"hints not array", func(m map[string]any) { m["language_hints"] = "sk" }, CodeInvalidRequest},
		{"empty hint", func(m map[string]any) { m["language_hints"] = []string{""} }, CodeInvalidRequest},
		{"stream_deltas string", func(m map[string]any) { m["stream_deltas"] = "yes" }, CodeInvalidRequest},
		{"stream_deltas number", func(m map[string]any) { m["stream_deltas"] = 1 }, CodeInvalidRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := validRequestJSON()
			tc.mutate(m)
			_, err := DecodeRequest(bytes.NewReader(encode(t, m)))
			var reqErr *RequestError
			if err == nil {
				t.Fatal("expected rejection")
			}
			if !errorsAs(err, &reqErr) || reqErr.Code != tc.code {
				t.Fatalf("code = %v, want %s", err, tc.code)
			}
			if strings.Contains(err.Error(), "peter") {
				t.Fatal("error must not echo the text")
			}
		})
	}
}

func errorsAs(err error, target **RequestError) bool {
	e, ok := err.(*RequestError)
	if ok {
		*target = e
	}
	return ok
}

func TestDecodeRequestRejectsNonObjectAndOversizedBody(t *testing.T) {
	for _, body := range []string{"[1,2]", "not json", `{"a":1} {"b":2}`} {
		if _, err := DecodeRequest(strings.NewReader(body)); err == nil {
			t.Fatalf("%q must be rejected", body)
		}
	}
	huge := validRequestJSON()
	huge["text"] = strings.Repeat("a", MaxRequestBodyBytes)
	_, err := DecodeRequest(bytes.NewReader(encode(t, huge)))
	var reqErr *RequestError
	if !errorsAs(err, &reqErr) || reqErr.Code != CodeTooLarge {
		t.Fatalf("oversized body must be too_large, got %v", err)
	}
}

func TestEventRoundTrips(t *testing.T) {
	req := Request{SchemaVersion: 1, RequestID: validID, Mode: "clean", Text: "peter moves"}
	q, first, total := 3, 182, 611
	events := []any{
		Accepted(validID),
		Progress(validID, 42),
		Delta(validID, "Peter, "),
		NewResult(req, "Peter moves.", Identity{"flowd", "0.2.0"}, Backend{"openai-compatible", "qwen"}, 1,
			Shield{1, 2, 2}, Timing{QueueMs: &q, BackendFirstTokenMs: &first, BackendMs: &total}),
		Error(validID, CodeBackendUnavailable, "The language model backend is not running."),
	}
	for _, event := range events {
		line, err := EncodeLine(event)
		if err != nil {
			t.Fatal(err)
		}
		if line[len(line)-1] != '\n' || bytes.Count(line, []byte{'\n'}) != 1 {
			t.Fatalf("line must end with exactly one newline: %q", line)
		}
		var generic map[string]any
		if err := json.Unmarshal(line, &generic); err != nil {
			t.Fatal(err)
		}
		if generic["request_id"] != validID {
			t.Fatalf("request_id missing on %s", generic["event"])
		}
		switch generic["event"] {
		case "accepted":
			var back Event
			json.Unmarshal(line, &back)
			if back != Accepted(validID) {
				t.Fatalf("accepted round trip: %+v", back)
			}
		case "progress":
			var back Event
			json.Unmarshal(line, &back)
			if back.GeneratedChars == nil || *back.GeneratedChars != 42 {
				t.Fatalf("progress round trip: %+v", back)
			}
		case "delta":
			var back Event
			json.Unmarshal(line, &back)
			if back.Text == nil || *back.Text != "Peter, " {
				t.Fatalf("delta round trip: %+v", back)
			}
		case "result":
			var back Result
			if err := json.Unmarshal(line, &back); err != nil {
				t.Fatal(err)
			}
			if back.Unchanged || back.Text != "Peter moves." || back.Server.Name != "flowd" ||
				back.Backend.Model != "qwen" || back.PromptVersion != 1 || back.Shield.Restored != 2 ||
				*back.Timing.BackendMs != 611 || back.SchemaVersion != 1 || back.Mode != "clean" {
				t.Fatalf("result round trip: %+v", back)
			}
			for _, key := range []string{"server", "backend", "prompt_version", "shield", "timing"} {
				if _, ok := generic[key]; !ok {
					t.Fatalf("result must carry %s", key)
				}
			}
		case "error":
			var back Event
			json.Unmarshal(line, &back)
			if back.Code != CodeBackendUnavailable || back.Message == "" {
				t.Fatalf("error round trip: %+v", back)
			}
			if _, has := generic["text"]; has {
				t.Fatal("error must not carry text")
			}
		default:
			t.Fatalf("unexpected event %v", generic["event"])
		}
	}
}

func TestUnchangedAndOmittedTiming(t *testing.T) {
	req := Request{SchemaVersion: 1, RequestID: validID, Mode: "concise", Text: "same"}
	line, err := EncodeLine(NewResult(req, "same", Identity{"flowd", "1"}, Backend{"fake", "m"}, 1, Shield{}, Timing{}))
	if err != nil {
		t.Fatal(err)
	}
	var generic map[string]any
	json.Unmarshal(line, &generic)
	if generic["unchanged"] != true {
		t.Fatal("unchanged must be true for identical text")
	}
	timing := generic["timing"].(map[string]any)
	if len(timing) != 0 {
		t.Fatalf("unmeasured spans must be omitted, got %v", timing)
	}
}

func TestEncodeLineBoundsNonResultEvents(t *testing.T) {
	if _, err := EncodeLine(Delta(validID, strings.Repeat("x", MaxLineBytes))); err != ErrLineTooLong {
		t.Fatalf("oversized delta must fail, got %v", err)
	}
	req := Request{SchemaVersion: 1, RequestID: validID, Mode: "clean", Text: strings.Repeat("a", 20000)}
	if _, err := EncodeLine(NewResult(req, strings.Repeat("b", 60000), Identity{"f", "1"}, Backend{"k", "m"}, 1, Shield{}, Timing{})); err != nil {
		t.Fatalf("result may exceed the per-line bound: %v", err)
	}
}

func TestHealthAndErrorBodyShapes(t *testing.T) {
	health := Health{
		SchemaVersion: 1, Service: ServiceName, ProtocolVersions: []int{1},
		Server: Identity{"flowd", "0.2.0"}, Modes: Modes,
		Backend:        HealthBackend{State: "ready", Kind: "openai-compatible", Model: "qwen"},
		PromptVersions: map[string]int{"clean": 1, "polished": 1, "concise": 1}, ShieldVersion: 1,
	}
	var generic map[string]any
	json.Unmarshal(encode(t, health), &generic)
	for _, key := range []string{"schema_version", "service", "protocol_versions", "server", "modes", "backend", "prompt_versions", "shield_version"} {
		if _, ok := generic[key]; !ok {
			t.Fatalf("health must carry %s", key)
		}
	}
	body := encode(t, NewErrorBody(CodeServerBusy, "Try again."))
	if string(body) != `{"error":{"code":"server_busy","message":"Try again."}}` {
		t.Fatalf("error body = %s", body)
	}
}

func TestBoundIdentityCutsAtRuneBoundary(t *testing.T) {
	long := strings.Repeat("é", 100)
	bounded := BoundIdentity(long)
	if len(bounded) > MaxIdentityBytes || !json.Valid(encode(t, bounded)) {
		t.Fatalf("bounded identity invalid: %d bytes", len(bounded))
	}
	if BoundIdentity("short") != "short" {
		t.Fatal("short identity must be unchanged")
	}
}

func TestIsUUID(t *testing.T) {
	if !IsUUID(validID) || !IsUUID(strings.ToLower(validID)) {
		t.Fatal("canonical UUIDs must be accepted")
	}
	for _, bad := range []string{"", "6F9619FF8B86D011B42D00C04FC964FF", validID + "0", "6F9619FF-8B86-D011-B42D-00C04FC964FG"} {
		if IsUUID(bad) {
			t.Fatalf("%q must be rejected", bad)
		}
	}
}

func TestRejectNullStreamFlagAndInvalidUTF8(t *testing.T) {
	for _, body := range []string{
		`{"schema_version":1,"request_id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","mode":"clean","text":"hello","language_hints":[],"stream_deltas":null}`,
		"{\"schema_version\":1,\"request_id\":\"6F9619FF-8B86-D011-B42D-00C04FC964FF\",\"mode\":\"clean\",\"text\":\"\xff\",\"language_hints\":[],\"stream_deltas\":false}",
	} {
		if _, err := DecodeRequest(strings.NewReader(body)); err == nil {
			t.Fatal("accepted invalid request")
		}
	}
}
