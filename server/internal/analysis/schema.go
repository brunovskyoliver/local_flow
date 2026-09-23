package analysis

import (
	_ "embed"
	"fmt"
	"time"
)

// resultSchemaJSON is a byte copy of protocol/schemas/analysis-result.schema.json;
// a test asserts it stays identical.
//
//go:embed result.schema.json
var resultSchemaJSON []byte

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

// clampList keeps the first cap entries — models order by significance, and an
// over-long section is a mechanical overflow, not a content defect. The client
// enforces the same caps, so an unbounded result could never be persisted.
// A missing list comes back empty: nil encodes as null, which the client
// rejects.
func clampList[T any](items []T, limit int) []T {
	if items == nil {
		return []T{}
	}
	if len(items) > limit {
		return items[:limit]
	}
	return items
}

func validateStructure(a *Analysis, partial bool) error {
	c := caps(partial)
	fail := func(reason string) error { return &RequestError{CodeOutputInvalid, reason} }
	if len(a.Summary.Text) < 1 || len(a.Summary.Text) > MaxSummaryBytes {
		return fail("summary.text length")
	}
	a.Summary.Sources = normalizeSources(a.Summary.Sources)
	a.Topics = clampList(a.Topics, c["topics"])
	a.Decisions = clampList(a.Decisions, c["decisions"])
	a.NextSteps = clampList(a.NextSteps, c["next_steps"])
	a.OpenQuestions = clampList(a.OpenQuestions, c["open_questions"])
	a.Risks = clampList(a.Risks, c["risks"])
	a.ActionItems = clampList(a.ActionItems, c["action_items"])
	for i := range a.Topics {
		a.Topics[i].Sources = normalizeSources(a.Topics[i].Sources)
		a.Topics[i].Bullets = clampList(a.Topics[i].Bullets, MaxTopicBullets)
	}
	for i := range a.Decisions {
		a.Decisions[i].Sources = normalizeSources(a.Decisions[i].Sources)
	}
	for i := range a.NextSteps {
		a.NextSteps[i].Sources = normalizeSources(a.NextSteps[i].Sources)
	}
	for i := range a.OpenQuestions {
		a.OpenQuestions[i].Sources = normalizeSources(a.OpenQuestions[i].Sources)
	}
	for i := range a.Risks {
		a.Risks[i].Sources = normalizeSources(a.Risks[i].Sources)
	}
	for i := range a.ActionItems {
		a.ActionItems[i].Sources = normalizeSources(a.ActionItems[i].Sources)
	}
	for i, t := range a.Topics {
		if len(t.Title) < 1 || len(t.Title) > MaxTopicTitle {
			return fail(fmt.Sprintf("topics[%d].title must be 1..%d bytes", i, MaxTopicTitle))
		}
		if len(t.Summary) > MaxTopicSummary {
			return fail(fmt.Sprintf("topics[%d].summary over %d bytes", i, MaxTopicSummary))
		}
		for j, b := range t.Bullets {
			if len(b) > MaxBulletBytes {
				return fail(fmt.Sprintf("topics[%d].bullets[%d] over %d bytes", i, j, MaxBulletBytes))
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
		for i, item := range section.items {
			if len(item.Text) < 1 || len(item.Text) > MaxItemText {
				return fail(fmt.Sprintf("%s[%d].text must be 1..%d bytes", section.name, i, MaxItemText))
			}
			if item.EvidenceClass != nil {
				if !section.evidenceAllowed ||
					(*item.EvidenceClass != "explicit" && *item.EvidenceClass != "implied") {
					return fail(section.name + " evidence_class")
				}
			}
			if len(item.Sources) < 1 {
				return fail(section.name + " needs at least 1 source")
			}
		}
	}
	for i, item := range a.ActionItems {
		if len(item.Text) < 1 || len(item.Text) > MaxItemText {
			return fail(fmt.Sprintf("action_items[%d].text must be 1..%d bytes", i, MaxItemText))
		}
		if len(item.Sources) < 1 {
			return fail("action_items needs at least 1 source")
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

// normalizeSources dedupes a citation list and clamps it to the schema cap.
// An over-long sources list is a mechanical overflow, not a content defect:
// every kept ref still resolves to real evidence, and rejecting a sound
// answer over it costs a full repair attempt the model may not survive.
func normalizeSources(sources []SourceRef) []SourceRef {
	seen := map[string]bool{}
	out := make([]SourceRef, 0, len(sources))
	for _, s := range sources {
		key := s.Kind + "\x00" + s.ID
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, s)
		if len(out) == MaxSourcesPerItem {
			break
		}
	}
	return out
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
