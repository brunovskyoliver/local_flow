package analysis

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"testing"
)

// The embedded schema is a byte copy of the shared contract file; drift fails
// here rather than at deploy time.
func TestEmbeddedSchemaMatchesProtocolFile(t *testing.T) {
	shared, err := os.ReadFile("../../../protocol/schemas/analysis-result.schema.json")
	if err != nil {
		t.Fatal(err)
	}
	if string(shared) != string(resultSchemaJSON) {
		t.Fatal("result.schema.json differs from protocol/schemas/analysis-result.schema.json")
	}
}

func requestForValidation(t *testing.T, stage string) *Request {
	t.Helper()
	body := validRequest()
	body["stage"] = stage
	if stage == StageChunk {
		body["chunk"] = map[string]any{"index": 0, "count": 2}
		body["notes"] = nil
	}
	if stage == StageSynthesis {
		body["segments"] = nil
		body["notes"] = nil
	}
	data, _ := json.Marshal(body)
	var r Request
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&r); err != nil {
		t.Fatal(err)
	}
	if err := r.validate(98304); err != nil {
		t.Fatal(err)
	}
	return &r
}

func minimalResult(meetingID string, partial bool) map[string]any {
	return map[string]any{
		"schema_version": 1, "meeting_id": meetingID, "partial": partial,
		"language": "sk",
		"summary": map[string]any{
			"text": "s", "sources": []any{}, "whole_meeting": true,
		},
		"topics": []any{}, "decisions": []any{
			map[string]any{"text": "d", "evidence_class": "explicit",
				"sources": []any{map[string]any{"kind": "segment", "id": uuid(2)}}},
		},
		"action_items": []any{}, "next_steps": []any{},
		"open_questions": []any{}, "risks": []any{},
	}
}

func validateResult(t *testing.T, result map[string]any, req *Request) (*Analysis, Code) {
	t.Helper()
	data, _ := json.Marshal(result)
	a, err := ValidateResult(data, req)
	var re *RequestError
	if errors.As(err, &re) {
		return a, re.Code
	}
	if err != nil {
		t.Fatalf("unexpected error type %v", err)
	}
	return a, ""
}

func TestValidateResultValid(t *testing.T) {
	req := requestForValidation(t, StageFull)
	a, code := validateResult(t, minimalResult(req.Meeting.ID, false), req)
	if code != "" || a == nil {
		t.Fatalf("valid result rejected: %s", code)
	}
}

func TestValidateResultRejections(t *testing.T) {
	req := requestForValidation(t, StageFull)
	cases := []struct {
		name   string
		mutate func(map[string]any)
		want   Code
	}{
		{"meeting mismatch", func(m map[string]any) {
			m["meeting_id"] = uuid(0xdead)
		}, CodeOutputInvalid},
		{"partial flag", func(m map[string]any) {
			m["partial"] = true
		}, CodeOutputInvalid},
		{"bad language", func(m map[string]any) {
			m["language"] = "de"
		}, CodeOutputInvalid},
		{"unknown field", func(m map[string]any) {
			m["extra"] = 1
		}, CodeOutputInvalid},
		{"over-cap decisions", func(m map[string]any) {
			items := []any{}
			for i := 0; i < 41; i++ {
				items = append(items, map[string]any{"text": "d",
					"sources": []any{map[string]any{"kind": "segment", "id": uuid(2)}}})
			}
			m["decisions"] = items
		}, CodeOutputInvalid},
		{"unknown source", func(m map[string]any) {
			m["decisions"] = []any{map[string]any{"text": "d",
				"sources": []any{map[string]any{"kind": "segment", "id": uuid(0xbeef)}}}}
		}, CodeSourceValidation},
		{"note source ok", func(m map[string]any) {
			m["decisions"] = []any{map[string]any{"text": "d",
				"sources": []any{map[string]any{"kind": "note", "id": "note:1"}}}}
		}, ""},
		{"owner not participant", func(m map[string]any) {
			m["action_items"] = []any{map[string]any{
				"text": "x",
				"owner": map[string]any{
					"kind": "participant", "speaker_id": uuid(0x777)},
				"ownership_state": "explicit", "due": map[string]any{"state": "absent"},
				"sources": []any{map[string]any{"kind": "segment", "id": uuid(2)}},
			}}
		}, CodeSourceValidation},
		{"bad due date", func(m map[string]any) {
			m["action_items"] = []any{map[string]any{
				"text": "x", "owner": map[string]any{"kind": "none"},
				"ownership_state": "unresolved",
				"due": map[string]any{
					"state": "explicit_absolute", "date": "2026-13-40",
					"original": "Friday",
					"source":   map[string]any{"kind": "segment", "id": uuid(2)},
				},
				"sources": []any{map[string]any{"kind": "segment", "id": uuid(2)}},
			}}
		}, CodeOutputInvalid},
		{"evidence on next step", func(m map[string]any) {
			m["next_steps"] = []any{map[string]any{"text": "x",
				"evidence_class": "explicit",
				"sources":        []any{map[string]any{"kind": "segment", "id": uuid(2)}}}}
		}, CodeOutputInvalid},
		{"mentioned explicit", func(m map[string]any) {
			m["action_items"] = []any{map[string]any{
				"text":            "x",
				"owner":           map[string]any{"kind": "mentioned", "name": "Tomáš"},
				"ownership_state": "explicit",
				"due":             map[string]any{"state": "absent"},
				"sources":         []any{map[string]any{"kind": "segment", "id": uuid(2)}},
			}}
		}, CodeOutputInvalid},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			result := minimalResult(req.Meeting.ID, false)
			tc.mutate(result)
			_, code := validateResult(t, result, req)
			if code != tc.want {
				t.Fatalf("want %s, got %s", tc.want, code)
			}
		})
	}
}

func TestValidateResultNonJSON(t *testing.T) {
	req := requestForValidation(t, StageFull)
	for _, raw := range [][]byte{
		[]byte("<think>reasoning</think>{}"),
		[]byte("prose first {}"),
		[]byte(""),
	} {
		if _, err := ValidateResult(raw, req); err == nil {
			t.Fatalf("accepted %q", raw)
		}
	}
}
