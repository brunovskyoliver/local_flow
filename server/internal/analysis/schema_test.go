package analysis

import (
	"bytes"
	"encoding/json"
	"fmt"
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
		body["partials"] = []any{minimalResult(uuid(0xf00d), true)}
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
			"text": "s", "sources": []any{}, "whole_meeting": !partial,
		},
		"topics": []any{}, "decisions": []any{
			map[string]any{"text": "d", "evidence_class": "explicit",
				"sources": []any{map[string]any{"kind": "segment", "id": uuid(2)}}},
		},
		"action_items": []any{}, "next_steps": []any{},
		"open_questions": []any{}, "risks": []any{},
	}
}

// The server builds the result in code, but the protocol's structural checks
// still run on it: over-cap lists are clamped, a source outside the request
// is rejected.
func TestBuiltResultStillValidated(t *testing.T) {
	req := requestForValidation(t, StageFull)
	src := []SourceRef{{Kind: "segment", ID: uuid(2)}}
	a := &Analysis{Summary: Summary{Text: "s", Sources: []SourceRef{}}}
	for i := 0; i < 41; i++ {
		a.Decisions = append(a.Decisions, Item{Text: fmt.Sprint("d", i), Sources: src})
	}
	if err := validateStructure(a, false); err != nil || len(a.Decisions) != 40 {
		t.Fatalf("want 40 decisions after clamp, got %d (%v)", len(a.Decisions), err)
	}
	// Nil lists come back empty: the client's decoder rejects null.
	data, _ := json.Marshal(a)
	if bytes.Contains(data, []byte("null")) {
		t.Fatalf("encoded result carries null: %s", data)
	}
	a.Decisions[0].Sources = []SourceRef{{Kind: "segment", ID: uuid(0xbeef)}}
	if err := validateSources(a, req); err == nil {
		t.Fatal("source outside the request accepted")
	}
}
