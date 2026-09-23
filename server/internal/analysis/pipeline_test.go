package analysis

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"localflow/server/internal/backend"
)

// scripted answers each call from a function of its prompt and records it.
type scripted struct {
	answer func(system, user string, temperature float64) (string, error)
	calls  []string
}

func (s *scripted) call(_ context.Context, system, user string, _ int, temperature float64) (string, error) {
	s.calls = append(s.calls, user)
	return s.answer(system, user, temperature)
}

func pipelineRequest(segments ...string) *Request {
	req := &Request{
		Stage:   StageChunk,
		Meeting: Meeting{ID: uuid(0xf00d), LanguagePolicy: LanguagePolicy{Output: "en"}},
		Participants: []Participant{
			{SpeakerID: uuid(1), Certainty: "local_name", Name: ptr("Martin Novák")},
			{SpeakerID: uuid(2), Certainty: "unknown"},
		},
	}
	for i, text := range segments {
		speaker := uuid(1 + i%2)
		req.Segments = append(req.Segments, Segment{ID: uuid(0x100 + i), SpeakerID: &speaker, Text: text})
	}
	return req
}

func runPipeline(t *testing.T, req *Request, s *scripted) *Analysis {
	t.Helper()
	p := newPipeline(req, s.call, DefaultLimits(), time.Now().Add(time.Minute))
	a, err := p.run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := validateStructure(a, req.Stage == StageChunk); err != nil {
		t.Fatal(err)
	}
	if err := validateSources(a, req); err != nil {
		t.Fatal(err)
	}
	return a
}

// The notes become a partial: headings in another language and bold form
// still parse, "none" lines vanish, every item cites the segment it rests
// on, an item resting on nothing is dropped, and a deadline counts only when
// it was said.
func TestNotesBecomePartial(t *testing.T) {
	req := pipelineRequest(
		"We agreed the invoice template changes to the blue layout.",
		"Martin will send the invoice on Friday.",
		"Who approves the budget is still unclear.",
	)
	s := &scripted{answer: func(string, string, float64) (string, error) {
		return "**Diskutované**\n- The invoice template\n## Rozhodnutia\n- Invoice template uses the blue layout\n- Rocket launch approved\n" +
			"## Commitments\n- Martin: send the invoice (due: Friday)\n- Speaker 2: approve budget (due: next Monday)\n- Nobody: reply\n" +
			"## Open questions\n- *None*\n## Risks\n- žiadne\n", nil
	}}
	a := runPipeline(t, req, s)
	if a.Summary.Text != "- The invoice template" || !a.Partial || a.Summary.WholeMeeting {
		t.Fatalf("summary: %+v", a.Summary)
	}
	if len(a.Decisions) != 1 || a.Decisions[0].Sources[0].ID != uuid(0x100) {
		t.Fatalf("decisions: %+v", a.Decisions)
	}
	if len(a.OpenQuestions) != 0 || len(a.Risks) != 0 {
		t.Fatalf("none lines kept: %+v %+v", a.OpenQuestions, a.Risks)
	}
	if len(a.ActionItems) != 2 {
		t.Fatalf("actions: %+v", a.ActionItems)
	}
	send := a.ActionItems[0]
	if send.Owner.Kind != "participant" || *send.Owner.SpeakerID != uuid(1) || send.OwnershipState != "explicit" {
		t.Fatalf("first-name owner not matched: %+v", send.Owner)
	}
	if send.Due.State != "unresolved" || *send.Due.Original != "Friday" || send.Due.Source.ID != uuid(0x101) {
		t.Fatalf("said deadline lost: %+v", send.Due)
	}
	approve := a.ActionItems[1]
	if approve.Owner.Kind != "participant" || *approve.Owner.SpeakerID != uuid(2) {
		t.Fatalf("Speaker 2 not mapped: %+v", approve.Owner)
	}
	if approve.Due.State != "absent" {
		t.Fatalf("unsaid deadline kept: %+v", approve.Due)
	}
	// The transcript the model read named speakers, never ids.
	if strings.Contains(s.calls[0], uuid(1)) || !strings.Contains(s.calls[0], "Martin Novák: We agreed") ||
		!strings.Contains(s.calls[0], "Speaker 2: Martin will") {
		t.Fatalf("transcript: %s", s.calls[0])
	}
}

// A part the server refuses for size splits in half until it fits.
func TestTooLargePartSplits(t *testing.T) {
	req := pipelineRequest("Alpha budget approved.", "Beta budget approved.", "Gamma budget approved.", "Delta budget approved.")
	s := &scripted{answer: func(_, user string, _ float64) (string, error) {
		if strings.Count(user, "\n") > 2 {
			return "", backend.ErrTooLarge
		}
		var decisions []string
		for _, line := range strings.Split(strings.TrimSpace(user), "\n") {
			decisions = append(decisions, "- "+strings.SplitN(line, ": ", 2)[1])
		}
		return "## Discussed\n- budgets\n## Decisions\n" + strings.Join(decisions, "\n"), nil
	}}
	a := runPipeline(t, req, s)
	if len(a.Decisions) != 4 {
		t.Fatalf("want all four decisions after the split, got %+v", a.Decisions)
	}
	for i, d := range a.Decisions {
		if d.Sources[0].ID != uuid(0x100+i) {
			t.Fatalf("decision %d grounded in %s", i, d.Sources[0].ID)
		}
	}
}

// An answer in the wrong language is asked again with the instruction
// repeated; the second answer wins.
func TestWrongLanguageRetried(t *testing.T) {
	req := pipelineRequest("Rozpočet na projekt schválili všetci účastníci stretnutia.")
	req.Meeting.LanguagePolicy.Output = "sk"
	english := "## Discussed\n- " + strings.Repeat("The budget for the project was approved by everyone present. ", 5)
	slovak := "## Discussed\n- Rozpočet na projekt schválili všetci účastníci."
	s := &scripted{answer: func(_, _ string, temperature float64) (string, error) {
		if temperature == 0 {
			return english, nil
		}
		return slovak, nil
	}}
	a := runPipeline(t, req, s)
	if len(s.calls) != 2 || !strings.Contains(s.calls[1], "Píš po slovensky") {
		t.Fatalf("no language retry: %d calls", len(s.calls))
	}
	if !strings.Contains(a.Summary.Text, "Rozpočet") {
		t.Fatalf("kept the wrong-language answer: %s", a.Summary.Text)
	}
}

// An English overview over Slovak topics is still the wrong language.
func TestMergeOverviewLanguageChecked(t *testing.T) {
	req := synthesisRequest(partialWith("- testovanie"))
	req.Meeting.LanguagePolicy.Output = "sk"
	topics := "## Topics\n### Automatizácia testovania\n- Šaňo a Oliver riešili nástroje, rozpočet a ďalšie kroky.\n"
	s := &scripted{answer: func(_, _ string, temperature float64) (string, error) {
		if temperature == 0 {
			return "## Overview\nThe meeting covered automation tools and the architecture for testing.\n" + topics, nil
		}
		return "## Overview\nStretnutie sa venovalo nástrojom na automatizáciu testovania.\n" + topics, nil
	}}
	a := runPipeline(t, req, s)
	if !strings.HasPrefix(a.Summary.Text, "Stretnutie") {
		t.Fatalf("kept the English overview: %s", a.Summary.Text)
	}
}

func partialWith(summary string, decisions ...string) Analysis {
	a := Analysis{Partial: true, Summary: Summary{Text: summary, Sources: []SourceRef{}},
		Topics: []Topic{}, ActionItems: []ActionItem{}, NextSteps: []Item{}, OpenQuestions: []Item{}, Risks: []Item{}}
	for i, d := range decisions {
		a.Decisions = append(a.Decisions, Item{Text: d, Sources: []SourceRef{{Kind: "segment", ID: uuid(0x500 + i)}}})
	}
	return a
}

func synthesisRequest(partials ...Analysis) *Request {
	return &Request{
		Stage:    StageSynthesis,
		Meeting:  Meeting{ID: uuid(0xf00d), LanguagePolicy: LanguagePolicy{Output: "en"}},
		Partials: partials,
	}
}

// Synthesis: the merge writes overview and topics, near-duplicate items
// collapse, and the review's numbers set the order of what is kept.
func TestSynthesisMergesAndReviews(t *testing.T) {
	req := synthesisRequest(
		partialWith("- pricing", "Price stays at 40 euro", "Launch moves to May", "Hire a designer"),
		partialWith("- launch", "Price stays at 40 euro.", "Office closes in August"),
	)
	s := &scripted{answer: func(system, _ string, _ float64) (string, error) {
		if strings.Contains(system, "numbered list") {
			return "Keep 4, 2 and 9", nil
		}
		return "## Overview\nPricing and launch were settled.\n## Topics\n### Pricing\n- 40 euro\n### Launch\n- May\n", nil
	}}
	a := runPipeline(t, req, s)
	if a.Summary.Text != "Pricing and launch were settled." || len(a.Topics) != 2 || a.Topics[1].Bullets[0] != "May" {
		t.Fatalf("merge: %+v %+v", a.Summary, a.Topics)
	}
	if len(a.Decisions) != 2 || a.Decisions[0].Text != "Office closes in August" || a.Decisions[1].Text != "Launch moves to May" {
		t.Fatalf("review order: %+v", a.Decisions)
	}
}

// A merge that never produces an overview falls back to the parts' own
// summaries; an unreadable review keeps the list. Nothing fails.
func TestSynthesisDegrades(t *testing.T) {
	req := synthesisRequest(
		partialWith("- pricing", "A one", "B two", "C three", "D four"),
		partialWith("- launch"),
	)
	s := &scripted{answer: func(string, string, float64) (string, error) { return "I cannot help with that.", nil }}
	p := newPipeline(req, s.call, DefaultLimits(), time.Now().Add(time.Minute))
	a, err := p.run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if a.Summary.Text != "- pricing\n- launch" || len(a.Decisions) != 4 {
		t.Fatalf("fallbacks: %q %+v", a.Summary.Text, a.Decisions)
	}
	if !strings.Contains(strings.Join(p.rejected, ","), "review_unreadable") {
		t.Fatalf("rejected: %v", p.rejected)
	}
}

// A preemption during an optional step still ends the request: the client
// retries preempted work, it must not get a silently thinner result.
func TestPreemptionIsNotAFallback(t *testing.T) {
	req := synthesisRequest(partialWith("- pricing", "A one", "B two", "C three", "D four"))
	s := &scripted{answer: func(system, _ string, _ float64) (string, error) {
		if strings.Contains(system, "numbered list") {
			return "", ErrPreempted
		}
		return "## Overview\nPricing.\n", nil
	}}
	p := newPipeline(req, s.call, DefaultLimits(), time.Now().Add(time.Minute))
	if _, err := p.run(context.Background()); !errors.Is(err, ErrPreempted) {
		t.Fatalf("want preempted, got %v", err)
	}
}

// Late in the request budget the optional calls are skipped.
func TestLateRequestSkipsReview(t *testing.T) {
	req := synthesisRequest(partialWith("- pricing", "A one", "B two", "C three", "D four"))
	s := &scripted{answer: func(string, string, float64) (string, error) { return "## Overview\nPricing.\n", nil }}
	p := newPipeline(req, s.call, DefaultLimits(), time.Now().Add(optionalReserve/2))
	if _, err := p.run(context.Background()); err != nil || len(s.calls) != 1 {
		t.Fatalf("calls %d, err %v", len(s.calls), err)
	}
}

func TestStemMatchMirrorsClient(t *testing.T) {
	for _, tc := range []struct {
		a, b string
		want bool
	}{
		{"faktúru", "faktúry", true}, {"invoice", "invoices", true},
		{"send", "sent", false}, {"budget", "budgetary", true}, {"plan", "planet", true},
	} {
		if got := stemMatch(fold(tc.a), fold(tc.b)); got != tc.want {
			t.Errorf("stemMatch(%s, %s) = %v", tc.a, tc.b, got)
		}
	}
}
