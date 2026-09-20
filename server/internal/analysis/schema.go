package analysis

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"time"
)

// resultSchemaJSON is a byte copy of protocol/schemas/analysis-result.schema.json;
// a test asserts it stays identical.
//
//go:embed result.schema.json
var resultSchemaJSON []byte

// ResponseFormat is the OpenAI response_format value for constrained decoding.
func ResponseFormat(stage string) map[string]any {
	var schema map[string]any
	_ = json.Unmarshal(resultSchemaJSON, &schema)
	return map[string]any{
		"type": "json_schema",
		"json_schema": map[string]any{
			"name": "analysis_" + stage, "strict": true, "schema": schema,
		},
	}
}

// Caps per section; chunk (partial) results use half.
var fullCaps = map[string]int{
	"topics": 20, "decisions": 40, "action_items": 60,
	"next_steps": 40, "open_questions": 40, "risks": 40,
}

func caps(partial bool) map[string]int {
	out := map[string]int{}
	for k, v := range fullCaps {
		if partial {
			out[k] = v / 2
		} else {
			out[k] = v
		}
	}
	return out
}

// ValidateResult decodes and checks a backend's analysis object for one
// request, in the contract's order: JSON decode, strict structure, meeting_id
// equality, every source_ref present in the request (for synthesis: the union
// of the partials' sources), owner.speaker_id among participants, due.date
// parses. Returns output_invalid or source_validation.
func ValidateResult(data []byte, req *Request) (*Analysis, error) {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || trimmed[0] != '{' || bytes.HasPrefix(trimmed, []byte("<think>")) {
		return nil, &RequestError{CodeOutputInvalid, "not a JSON object"}
	}
	var a Analysis
	decoder := json.NewDecoder(bytes.NewReader(trimmed))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&a); err != nil || decoder.More() {
		return nil, &RequestError{CodeOutputInvalid, "malformed or unknown field"}
	}
	if a.SchemaVersion != SchemaVersion {
		return nil, &RequestError{CodeOutputInvalid, "schema_version"}
	}
	if a.MeetingID != req.Meeting.ID {
		return nil, &RequestError{CodeOutputInvalid, "meeting_id"}
	}
	partial := req.Stage == StageChunk
	if a.Partial != partial {
		return nil, &RequestError{CodeOutputInvalid, "partial flag"}
	}
	switch a.Language {
	case "sk", "en", "mixed":
	default:
		return nil, &RequestError{CodeOutputInvalid, "language"}
	}
	if err := validateStructure(&a, partial); err != nil {
		return nil, err
	}
	return &a, validateSources(&a, req)
}

func validateStructure(a *Analysis, partial bool) error {
	c := caps(partial)
	fail := func(reason string) error { return &RequestError{CodeOutputInvalid, reason} }
	if len(a.Summary.Text) < 1 || len(a.Summary.Text) > MaxSummaryBytes {
		return fail("summary.text length")
	}
	if len(a.Summary.Sources) > MaxSourcesPerItem {
		return fail("summary.sources over 10")
	}
	if len(a.Topics) > c["topics"] {
		return fail("topics over cap")
	}
	for _, t := range a.Topics {
		if len(t.Title) < 1 || len(t.Title) > MaxTopicTitle ||
			len(t.Summary) > MaxTopicSummary || len(t.Bullets) > MaxTopicBullets ||
			len(t.Sources) > MaxSourcesPerItem {
			return fail("topic field bound")
		}
		for _, b := range t.Bullets {
			if len(b) > MaxBulletBytes {
				return fail("bullet over 500 bytes")
			}
		}
	}
	sections := []struct {
		name  string
		items []Item
		// evidence_class is not permitted on next_steps.
		evidenceAllowed bool
	}{
		{"decisions", a.Decisions, true},
		{"next_steps", a.NextSteps, false},
		{"open_questions", a.OpenQuestions, true},
		{"risks", a.Risks, true},
	}
	for _, section := range sections {
		if len(section.items) > c[section.name] {
			return fail(section.name + " over cap")
		}
		for _, item := range section.items {
			if len(item.Text) < 1 || len(item.Text) > MaxItemText {
				return fail(section.name + " text bound")
			}
			if item.EvidenceClass != nil {
				if !section.evidenceAllowed ||
					(*item.EvidenceClass != "explicit" && *item.EvidenceClass != "implied") {
					return fail(section.name + " evidence_class")
				}
			}
			if len(item.Sources) < 1 || len(item.Sources) > MaxSourcesPerItem {
				return fail(section.name + " sources 1..10")
			}
			if err := uniqueSources(item.Sources); err != nil {
				return err
			}
		}
	}
	if len(a.ActionItems) > c["action_items"] {
		return fail("action_items over cap")
	}
	for _, item := range a.ActionItems {
		if len(item.Text) < 1 || len(item.Text) > MaxItemText ||
			len(item.Sources) < 1 || len(item.Sources) > MaxSourcesPerItem {
			return fail("action_item bound")
		}
		if err := uniqueSources(item.Sources); err != nil {
			return err
		}
		switch item.Owner.Kind {
		case "participant":
			if item.Owner.SpeakerID == nil || !isUUID(*item.Owner.SpeakerID) ||
				item.Owner.Name != nil {
				return fail("participant owner needs speaker_id only")
			}
		case "mentioned":
			if item.Owner.Name == nil || len(*item.Owner.Name) < 1 ||
				len(*item.Owner.Name) > MaxNameBytes || item.Owner.SpeakerID != nil {
				return fail("mentioned owner needs name only")
			}
		case "none":
			if item.Owner.SpeakerID != nil || item.Owner.Name != nil {
				return fail("none owner carries no fields")
			}
		default:
			return fail("owner.kind")
		}
		switch item.OwnershipState {
		case "explicit", "supported", "unresolved":
		default:
			return fail("ownership_state")
		}
		if item.Owner.Kind == "mentioned" && item.OwnershipState == "explicit" {
			return fail("mentioned owner is at most supported")
		}
		if item.Owner.Kind == "none" && item.OwnershipState != "unresolved" {
			return fail("none owner is unresolved")
		}
		if err := validateDue(item.Due); err != nil {
			return err
		}
	}
	return nil
}

func uniqueSources(sources []SourceRef) error {
	seen := map[string]bool{}
	for _, s := range sources {
		key := s.Kind + "\x00" + s.ID
		if seen[key] {
			return &RequestError{CodeOutputInvalid, "duplicate source"}
		}
		seen[key] = true
	}
	return nil
}

func validateDue(due Due) error {
	fail := func(reason string) error { return &RequestError{CodeOutputInvalid, reason} }
	switch due.State {
	case "explicit_absolute", "explicit_relative_resolved":
		if due.Date == nil || due.Original == nil || due.Source == nil {
			return fail("explicit due needs date, original and source")
		}
		if _, err := time.Parse("2006-01-02", *due.Date); err != nil {
			return fail("due.date must be YYYY-MM-DD")
		}
	case "unresolved":
		if due.Date != nil || due.Original == nil || due.Source == nil {
			return fail("unresolved due keeps original and source, no date")
		}
	case "absent":
		if due.Date != nil || due.Original != nil || due.Source != nil {
			return fail("absent due carries nothing")
		}
	default:
		return fail("due.state")
	}
	if due.Original != nil &&
		(len(*due.Original) < 1 || len(*due.Original) > MaxDueOriginal) {
		return fail("due.original 1..80 bytes")
	}
	return nil
}

// validateSources checks every source_ref resolves against the request: a
// segment id of this request (for synthesis, the union of the partials'
// sources) or a note:<n> the request carries; owner speaker_ids must name a
// participant.
func validateSources(a *Analysis, req *Request) error {
	valid := map[string]bool{}
	for _, s := range req.Segments {
		valid["segment\x00"+s.ID] = true
	}
	for _, n := range req.Notes {
		valid["note\x00"+n.ID] = true
	}
	for _, p := range req.Partials {
		collectSources(p, func(kind, id string) { valid[kind+"\x00"+id] = true })
	}
	participants := map[string]bool{}
	for _, p := range req.Participants {
		participants[p.SpeakerID] = true
	}
	check := func(s SourceRef) error {
		if s.Kind != "segment" && s.Kind != "note" {
			return &RequestError{CodeOutputInvalid, "source kind"}
		}
		if !valid[s.Kind+"\x00"+s.ID] {
			return &RequestError{CodeSourceValidation, s.ID}
		}
		return nil
	}
	for _, s := range a.Summary.Sources {
		if err := check(s); err != nil {
			return err
		}
	}
	for _, t := range a.Topics {
		for _, s := range t.Sources {
			if err := check(s); err != nil {
				return err
			}
		}
	}
	for _, items := range [][]Item{a.Decisions, a.NextSteps, a.OpenQuestions, a.Risks} {
		for _, item := range items {
			for _, s := range item.Sources {
				if err := check(s); err != nil {
					return err
				}
			}
		}
	}
	for _, item := range a.ActionItems {
		for _, s := range item.Sources {
			if err := check(s); err != nil {
				return err
			}
		}
		if item.Due.Source != nil {
			if err := check(*item.Due.Source); err != nil {
				return err
			}
		}
		if item.Owner.Kind == "participant" &&
			!participants[*item.Owner.SpeakerID] {
			return &RequestError{CodeSourceValidation, "owner speaker_id"}
		}
	}
	return nil
}

func collectSources(a Analysis, visit func(kind, id string)) {
	for _, s := range a.Summary.Sources {
		visit(s.Kind, s.ID)
	}
	for _, t := range a.Topics {
		for _, s := range t.Sources {
			visit(s.Kind, s.ID)
		}
	}
	for _, items := range [][]Item{a.Decisions, a.NextSteps, a.OpenQuestions, a.Risks} {
		for _, i := range items {
			for _, s := range i.Sources {
				visit(s.Kind, s.ID)
			}
		}
	}
	for _, i := range a.ActionItems {
		for _, s := range i.Sources {
			visit(s.Kind, s.ID)
		}
		if i.Due.Source != nil {
			visit(i.Due.Source.Kind, i.Due.Source.ID)
		}
	}
}
