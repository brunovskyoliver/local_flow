package analysis

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func uuid(i int) string {
	return fmt.Sprintf("aaaa%04x-0000-4000-8000-%012d", i, i)
}

func validMeeting() map[string]any {
	return map[string]any{
		"id":          uuid(0xf00d),
		"title":       "Sync",
		"started_at":  "2026-09-20T09:00:00+02:00",
		"duration_ms": 60_000,
		"time_zone":   "Europe/Bratislava",
		"language_policy": map[string]any{
			"output": "sk", "preserve_terms": true,
		},
	}
}

func validParticipant(i int) map[string]any {
	return map[string]any{
		"speaker_id": uuid(i), "certainty": "local_name", "origin": "none",
		"name": "Martin",
	}
}

func validSegment(i int, speaker *string) map[string]any {
	return map[string]any{
		"id": uuid(i), "start_ms": 0, "end_ms": 1000,
		"speaker_id": speaker, "text": "Hello.",
	}
}

func validRequest() map[string]any {
	return map[string]any{
		"schema_version": 1, "request_id": uuid(0x100), "run_id": uuid(0x200),
		"priority": "background", "stage": "full",
		"meeting":      validMeeting(),
		"participants": []any{validParticipant(1)},
		"segments":     []any{validSegment(2, ptr(uuid(1)))},
		"notes":        []any{map[string]any{"id": "note:1", "text": "A note"}},
	}
}

func ptr(s string) *string { return &s }

func decode(t *testing.T, body map[string]any) (*Request, Code) {
	t.Helper()
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req, derr := DecodeRequest(bytes.NewReader(data), 98304)
	var re *RequestError
	if errors.As(derr, &re) {
		return req, re.Code
	}
	if derr != nil {
		t.Fatalf("unexpected error type: %v", derr)
	}
	return req, ""
}

func TestDecodeValidRequest(t *testing.T) {
	req, code := decode(t, validRequest())
	if code != "" || req == nil {
		t.Fatalf("valid request rejected: %s", code)
	}
	if req.Stage != StageFull || req.Meeting.ID != uuid(0xf00d) {
		t.Fatalf("wrong decode: %+v", req)
	}
}

func TestDecodeChunkRequest(t *testing.T) {
	body := validRequest()
	body["stage"] = "chunk"
	body["chunk"] = map[string]any{"index": 2, "count": 9}
	body["notes"] = nil
	req, code := decode(t, body)
	if code != "" || req.Chunk.Index != 2 {
		t.Fatalf("chunk request rejected: %s", code)
	}
}

func TestRejections(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(map[string]any)
		want   Code
	}{
		{"unknown field", func(b map[string]any) { b["extra"] = 1 }, CodeInvalidRequest},
		{"schema version", func(b map[string]any) { b["schema_version"] = 2 }, CodeUnsupportedVersion},
		{"bad request id", func(b map[string]any) { b["request_id"] = "x" }, CodeInvalidRequest},
		{"priority", func(b map[string]any) { b["priority"] = "interactive" }, CodeInvalidRequest},
		{"stage", func(b map[string]any) { b["stage"] = "partial" }, CodeInvalidRequest},
		{"chunk on full", func(b map[string]any) {
			b["chunk"] = map[string]any{"index": 0, "count": 1}
		}, CodeInvalidRequest},
		{"chunk index >= count", func(b map[string]any) {
			b["stage"] = "chunk"
			b["chunk"] = map[string]any{"index": 2, "count": 2}
		}, CodeInvalidRequest},
		{"chunk missing", func(b map[string]any) {
			b["stage"] = "chunk"
		}, CodeInvalidRequest},
		{"chunk count over 64", func(b map[string]any) {
			b["stage"] = "chunk"
			b["chunk"] = map[string]any{"index": 0, "count": 65}
		}, CodeInvalidRequest},
		{"meeting id", func(b map[string]any) {
			b["meeting"].(map[string]any)["id"] = "nope"
		}, CodeInvalidRequest},
		{"title too long", func(b map[string]any) {
			b["meeting"].(map[string]any)["title"] = strings.Repeat("t", 257)
		}, CodeInvalidRequest},
		{"started_at missing offset", func(b map[string]any) {
			b["meeting"].(map[string]any)["started_at"] = "2026-09-20T09:00:00"
		}, CodeInvalidRequest},
		{"bad time zone", func(b map[string]any) {
			b["meeting"].(map[string]any)["time_zone"] = "Not/AZone"
		}, CodeInvalidRequest},
		{"bad language", func(b map[string]any) {
			b["meeting"].(map[string]any)["language_policy"] = map[string]any{"output": "de"}
		}, CodeInvalidRequest},
		{"duplicate speaker", func(b map[string]any) {
			b["participants"] = []any{validParticipant(1), validParticipant(1)}
		}, CodeInvalidRequest},
		{"name with possible", func(b map[string]any) {
			p := validParticipant(1)
			p["certainty"] = "possible"
			b["participants"] = []any{p}
		}, CodeInvalidRequest},
		{"known speaker with local_name", func(b map[string]any) {
			p := validParticipant(1)
			p["known_speaker_id"] = uuid(9)
			b["participants"] = []any{p}
		}, CodeInvalidRequest},
		{"known speaker confirmed ok", func(b map[string]any) {
			p := validParticipant(1)
			p["certainty"] = "confirmed"
			p["known_speaker_id"] = uuid(9)
			b["participants"] = []any{p}
		}, ""},
		{"duplicate segment id", func(b map[string]any) {
			b["segments"] = []any{validSegment(2, nil), validSegment(2, nil)}
		}, CodeInvalidRequest},
		{"end before start", func(b map[string]any) {
			s := validSegment(2, nil)
			s["end_ms"] = -1
			b["segments"] = []any{s}
		}, CodeInvalidRequest},
		{"segment speaker not participant", func(b map[string]any) {
			b["segments"] = []any{validSegment(2, ptr(uuid(77)))}
		}, CodeInvalidRequest},
		{"empty segment text", func(b map[string]any) {
			s := validSegment(2, nil)
			s["text"] = ""
			b["segments"] = []any{s}
		}, CodeInvalidRequest},
		{"segments absent for synthesis", func(b map[string]any) {
			b["stage"] = "synthesis"
		}, CodeInvalidRequest},
		{"partials missing for synthesis", func(b map[string]any) {
			b["stage"] = "synthesis"
			b["segments"] = nil
		}, CodeInvalidRequest},
		{"partials on full", func(b map[string]any) {
			b["partials"] = []any{}
		}, CodeInvalidRequest},
		{"notes on chunk", func(b map[string]any) {
			b["stage"] = "chunk"
			b["chunk"] = map[string]any{"index": 0, "count": 1}
		}, CodeInvalidRequest},
		{"note ids not increasing", func(b map[string]any) {
			b["notes"] = []any{
				map[string]any{"id": "note:2", "text": "b"},
				map[string]any{"id": "note:1", "text": "a"},
			}
		}, CodeInvalidRequest},
		{"note id shape", func(b map[string]any) {
			b["notes"] = []any{map[string]any{"id": "n:1", "text": "a"}}
		}, CodeInvalidRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := validRequest()
			tc.mutate(body)
			_, code := decode(t, body)
			if code != tc.want {
				t.Fatalf("want %s, got %s", tc.want, code)
			}
		})
	}
}

func TestInputByteLimit(t *testing.T) {
	body := validRequest()
	body["segments"] = []any{
		validSegment(2, nil), validSegment(3, nil), validSegment(4, nil),
	}
	_, code := decodeLimit(t, body, 10)
	if code != CodeTooLarge {
		t.Fatalf("want too_large, got %s", code)
	}
}

func decodeLimit(t *testing.T, body map[string]any, limit int) (*Request, Code) {
	t.Helper()
	data, _ := json.Marshal(body)
	_, derr := DecodeRequest(bytes.NewReader(data), limit)
	var re *RequestError
	if errors.As(derr, &re) {
		return nil, re.Code
	}
	if derr != nil {
		t.Fatalf("unexpected: %v", derr)
	}
	return nil, ""
}

func TestBodyByteLimit(t *testing.T) {
	big := bytes.NewReader(make([]byte, MaxRequestBodyBytes+2))
	_, err := DecodeRequest(big, 98304)
	var re *RequestError
	if !errors.As(err, &re) || re.Code != CodeTooLarge {
		t.Fatalf("want too_large, got %v", err)
	}
}
