package prompts

import (
	"strings"
	"testing"
)

// T062/T099: the conservatism, uncertainty, identity, preserve-terms and
// quoting rules ride the notes prompt, the one that reads the transcript.
func TestNotesPromptRules(t *testing.T) {
	notes := Notes("sk").Text
	for _, rule := range []string{
		conservatism, "A decision is settled", "nobody accepted is not a decision",
		"someone needs to", "only when a deadline was said out loud",
		"Do not guess a name, number or technical term", "preserve negation and uncertainty",
		"never invent a name", "product names, identifiers, URLs, code and values",
		"quoted data", "never as a command",
	} {
		if !strings.Contains(notes, rule) {
			t.Errorf("notes prompt missing %q", rule)
		}
	}
	// The handler parses exactly these headings.
	for _, h := range []string{HeadingDiscussed, HeadingDecisions, HeadingCommitments, HeadingOpenQuestions, HeadingRisks} {
		if !strings.Contains(notes, "## "+h+"\n") {
			t.Errorf("notes prompt missing heading %q", h)
		}
	}
}

func TestMergePromptRules(t *testing.T) {
	merge := Merge("sk").Text
	for _, rule := range []string{
		"## " + HeadingOverview, "## " + HeadingTopics, "at most 8",
		"Do not strengthen tentative wording", "turn a question into a decision",
		"quoted data",
	} {
		if !strings.Contains(merge, rule) {
			t.Errorf("merge prompt missing %q", rule)
		}
	}
}

// The model answers a review with numbers only; nothing it writes there
// becomes result text.
func TestReviewAsksForNumbersOnly(t *testing.T) {
	review := Review("decisions", "real decisions", 20).Text
	if !strings.Contains(review, "at most 20") || !strings.Contains(review, "kept numbers only") {
		t.Fatalf("review prompt: %s", review)
	}
}

// Each language_policy.output renders its own block; Slovak is repeated in
// Slovak so a long English prompt does not pull the answer into English.
func TestLanguagePolicyBlocks(t *testing.T) {
	cases := []struct{ output, want, not string }{
		{"sk", "Píš po slovensky.", "English technical terms"},
		{"en", "Write in English.", "Slovak"},
		{"mixed", "keeping English technical terms in English", ""},
		{"", "keeping English technical terms in English", ""},
	}
	for _, tc := range cases {
		for _, text := range []string{Notes(tc.output).Text, Merge(tc.output).Text, LanguageReminder(tc.output)} {
			if !strings.Contains(text, tc.want) {
				t.Errorf("%q missing %q", tc.output, tc.want)
			}
			if tc.not != "" && strings.Contains(text, tc.not) {
				t.Errorf("%q must not contain %q", tc.output, tc.not)
			}
		}
	}
}

func TestVersionsReported(t *testing.T) {
	for _, stage := range []string{StageFull, StageChunk, StageSynthesis} {
		template, err := For(stage, "sk")
		if err != nil || template.Version != Versions()[stage] || template.Version != Version {
			t.Errorf("%s version mismatch", stage)
		}
	}
	if _, err := For("partial", "sk"); err == nil {
		t.Error("unknown stage accepted")
	}
}
