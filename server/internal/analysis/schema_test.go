package analysis

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
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

func TestValidateResultLanguageMustMatchEveryStage(t *testing.T) {
	for _, stage := range []string{StageFull, StageChunk, StageSynthesis} {
		for _, language := range []string{"sk", "en", "mixed"} {
			req := requestForValidation(t, StageFull)
			req.Stage = stage
			req.Meeting.LanguagePolicy.Output = language
			for _, returned := range []string{"sk", "en", "mixed"} {
				result := minimalResult(req.Meeting.ID, stage == StageChunk)
				result["language"] = returned
				result["decisions"] = []any{}
				_, code := validateResult(t, result, req)
				if (code == "") != (language == returned) {
					t.Errorf("%s requested %s returned %s: %s", stage, language, returned, code)
				}
			}
		}
	}
}

func TestValidateResultRejections(t *testing.T) {
	req := requestForValidation(t, StageFull)
	cases := []struct {
		name   string
		mutate func(map[string]any)
		want   Code
	}{
		{"meeting id normalized", func(m map[string]any) {
			m["meeting_id"] = uuid(0xdead) // a garbled echo; the server sets it
		}, ""},
		{"partial flag normalized", func(m map[string]any) {
			m["partial"] = true // wrong for a full request; fixed per stage
		}, ""},
		{"bad language", func(m map[string]any) {
			m["language"] = "de"
		}, CodeOutputInvalid},
		{"unknown field", func(m map[string]any) {
			m["extra"] = 1
		}, CodeOutputInvalid},
		{"over-cap decisions clamped", func(m map[string]any) {
			items := []any{}
			for i := 0; i < 41; i++ {
				items = append(items, map[string]any{"text": "d",
					"sources": []any{map[string]any{"kind": "segment", "id": uuid(2)}}})
			}
			m["decisions"] = items
		}, ""},
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

// Small models drop closers mid-document, dangle commas, and get cut at the
// token cap; the fixer only touches structure, never content.
func TestRepairJSONShape(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   string
		ok   bool
	}{
		{"dropped item brace", `{"a":[{"c":1]}`, true},
		{"dropped nested closers", `{"a":{"b":[1,2]}`, true},
		{"dangling comma", `{"a":1,}`, true},
		{"unterminated string", `{"a":"text`, true},
		{"truncated mid-structure", `{"a":{"b":[1,2`, true},
		{"trailing junk", `{"a":1} note to self`, true},
		{"already valid", `{"a":1}`, true},
		{"stray closer dropped", `{"a":1}]`, true},
		{"escaped quote at EOF", `{"a":"x\`, false},
		{"closer with nothing open", `}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			out, ok := repairJSONShape([]byte(tc.in))
			if ok != tc.ok {
				t.Fatalf("ok=%v for %q", ok, tc.in)
			}
			if ok && !json.Valid(out) {
				t.Fatalf("invalid repair %q -> %q", tc.in, out)
			}
		})
	}
}

// A sources list over the cap is normalized — deduped, truncated — instead of
// rejecting an otherwise sound result; every kept ref still resolves.
func TestValidateResultSourcesNormalized(t *testing.T) {
	req := requestForValidation(t, StageFull)
	raw := []byte(`{"schema_version":1,"meeting_id":"` + req.Meeting.ID +
		`","partial":false,"language":"sk",` +
		`"summary":{"text":"s","sources":[],"whole_meeting":true},` +
		`"topics":[],"decisions":[{"text":"d","evidence_class":"explicit",` +
		`"sources":[{"kind":"segment","id":"` + uuid(2) + `"},` +
		`{"kind":"segment","id":"` + uuid(2) + `"},` +
		`{"kind":"note","id":"note:1"},{"kind":"note","id":"note:1"}]}]` +
		`,"action_items":[],"next_steps":[],"open_questions":[],"risks":[]}`)
	a, err := ValidateResult(raw, req)
	if err != nil || len(a.Decisions[0].Sources) != 2 {
		t.Fatalf("want deduped sources, got %v %v", a, err)
	}
}

// Over-long lists — sections and topic bullets — are clamped to the schema
// caps rather than rejected: models emit entries in rough significance order
// and the client enforces the same caps, so an unbounded result could never
// persist anyway.
func TestValidateResultClampsLists(t *testing.T) {
	req := requestForValidation(t, StageFull)
	result := minimalResult(req.Meeting.ID, false)
	bullets := []any{}
	for i := 0; i < 91; i++ {
		bullets = append(bullets, fmt.Sprintf("bullet %d", i))
	}
	result["topics"] = []any{map[string]any{
		"title": "t", "summary": "s", "bullets": bullets, "sources": []any{},
	}}
	risks := []any{}
	for i := 0; i < 45; i++ {
		risks = append(risks, map[string]any{
			"text": fmt.Sprintf("r%d", i),
			"sources": []any{
				map[string]any{"kind": "segment", "id": uuid(2)},
			},
		})
	}
	result["risks"] = risks
	raw, _ := json.Marshal(result)
	a, err := ValidateResult(raw, req)
	if err != nil {
		t.Fatalf("want clamped result, got %v", err)
	}
	if len(a.Topics[0].Bullets) != MaxTopicBullets || len(a.Risks) != 40 {
		t.Fatalf("want 12 bullets and 40 risks, got %d and %d",
			len(a.Topics[0].Bullets), len(a.Risks))
	}
}

// Dropped braces mid-document were a signature failure of the served model:
// the item object's closer went missing before the decisions array closed.
func TestValidateResultRepairsDroppedBrace(t *testing.T) {
	req := requestForValidation(t, StageFull)
	raw := []byte(`{"schema_version":1,"meeting_id":"` + req.Meeting.ID +
		`","partial":false,"language":"sk",` +
		`"summary":{"text":"s","sources":[],"whole_meeting":true},` +
		`"topics":[],"decisions":[{"text":"d","evidence_class":"explicit",` +
		`"sources":[{"kind":"segment","id":"` + uuid(2) + `"}]]` +
		`,"action_items":[],"next_steps":[],"open_questions":[],"risks":[]}`)
	a, err := ValidateResult(raw, req)
	if err != nil || len(a.Decisions) != 1 {
		t.Fatalf("want repaired result, got %v %v", a, err)
	}
}

// The client's decoder rejects null where the contract says "absent": a
// re-encoded result must omit unset optionals and carry [] for empty lists.
func TestValidatedResultEncodesWithoutNulls(t *testing.T) {
	req := requestForValidation(t, StageFull)
	result := minimalResult(req.Meeting.ID, false)
	delete(result, "risks")
	src := []any{map[string]any{"kind": "segment", "id": uuid(2)}}
	result["topics"] = []any{map[string]any{"title": "t", "summary": "", "sources": src}}
	result["next_steps"] = []any{map[string]any{"text": "n", "sources": src}}
	result["action_items"] = []any{map[string]any{
		"text": "a", "owner": map[string]any{"kind": "none"},
		"ownership_state": "unresolved", "due": map[string]any{"state": "absent"},
		"sources": src,
	}}
	a, code := validateResult(t, result, req)
	if code != "" {
		t.Fatalf("rejected: %s", code)
	}
	data, _ := json.Marshal(a)
	if bytes.Contains(data, []byte("null")) {
		t.Fatalf("encoded result carries null: %s", data)
	}
}

// The model reads short aliases and answers with them; validation maps them
// back to the request's UUIDs, and an unknown alias still fails.
func TestAliasesRoundTrip(t *testing.T) {
	req := requestForValidation(t, StageFull)
	text, err := renderUserText(req)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range req.Segments {
		if strings.Contains(text, s.ID) {
			t.Fatalf("prompt carries segment UUID %s", s.ID)
		}
	}
	a := newAliases(req)
	alias := a.short[req.Segments[0].ID]
	result := minimalResult(req.Meeting.ID, false)
	result["decisions"] = []any{map[string]any{"text": "d",
		"sources": []any{map[string]any{"kind": "segment", "id": alias}}}}
	got, code := validateResult(t, result, req)
	if code != "" || got.Decisions[0].Sources[0].ID != req.Segments[0].ID {
		t.Fatalf("alias %s not restored: %s %+v", alias, code, got)
	}
	result["decisions"] = []any{map[string]any{"text": "d",
		"sources": []any{map[string]any{"kind": "segment", "id": "s999"}}}}
	if _, code := validateResult(t, result, req); code != CodeSourceValidation {
		t.Fatalf("unknown alias accepted: %s", code)
	}
}

// Field names inside "properties" survive keyword stripping.
func TestConstraintSchemaKeepsTopicTitle(t *testing.T) {
	if !strings.Contains(string(constraintSchemaJSON), `"title":{`) {
		t.Fatal("topic title property stripped from the constraint schema")
	}
	if strings.Contains(string(constraintSchemaJSON), `"format"`) {
		t.Fatal("format keyword left in the constraint schema")
	}
}
