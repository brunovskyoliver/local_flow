package analysis

import "time"

// Limits holds the --analysis-* flag values (defaults from the contract's
// "Server bounds and flags" table).
type Limits struct {
	Enabled           bool
	Concurrency       int
	InputBytes        int
	OutputBytes       int
	ContextTokens     int
	ConcurrencyWait   time.Duration
	Timeout           time.Duration
	FirstTokenTimeout time.Duration
	QueueWait         time.Duration
	Preempt           bool
	OutputTokensChunk int
	OutputTokensFull  int
}

func DefaultLimits() Limits {
	return Limits{
		Enabled:       true,
		Concurrency:   1,
		InputBytes:    98304,
		OutputBytes:   MaxLineBytes,
		ContextTokens: 32768,
		// A part is ~6k prompt tokens; a 4B model on Apple Silicon needs seconds
		// of prefill before its first token when nothing is cached, more under
		// load. Timeout bounds every backend call of one request together and
		// stays under the client's 300 s per-request deadline, so the client
		// gets a result or an error rather than its own timeout.
		Timeout:           270 * time.Second,
		FirstTokenTimeout: 60 * time.Second,
		QueueWait:         30 * time.Second,
		Preempt:           true,
		// Notes for one part ran 200–700 tokens in the ADR 0022 prototype and
		// the merged overview 1.4–2k; the caps bound a runaway decode (and its
		// KV growth) instead of letting it spend minutes.
		OutputTokensChunk: 1024,
		OutputTokensFull:  2048,
	}
}

// OutputTokens is the largest backend max_tokens a stage's calls use: notes
// for chunk, the merge for full and synthesis.
func (l Limits) OutputTokens(stage string) int {
	if stage == StageChunk {
		return l.OutputTokensChunk
	}
	return l.OutputTokensFull
}

// reserved instruction + output tokens per the contract's estimate rule:
// input bytes / 3 + instruction and output reservations. The prompts no
// longer carry the result schema (ADR 0022).
const instructionReserveTokens = 900

// EstimateTokens approximates the context usage of one request.
func (l Limits) EstimateTokens(textBytes int, stage string) int {
	return textBytes/3 + instructionReserveTokens + l.OutputTokens(stage)
}

// ExceedsContext reports whether a request carrying `textBytes` of user text
// would overflow the configured context.
func (l Limits) ExceedsContext(textBytes int, stage string) bool {
	return l.EstimateTokens(textBytes, stage) > l.ContextTokens
}

// InputTextBytes sums the text the request carries (segments, notes, partials).
func (r *Request) InputTextBytes() int {
	total := 0
	for _, s := range r.Segments {
		total += len(s.Text)
	}
	for _, n := range r.Notes {
		total += len(n.Text)
	}
	for _, p := range r.Partials {
		total += partialTextBytes(p)
	}
	return total
}

func partialTextBytes(a Analysis) int {
	total := len(a.Summary.Text)
	for _, t := range a.Topics {
		total += len(t.Title) + len(t.Summary)
		for _, b := range t.Bullets {
			total += len(b)
		}
	}
	for _, items := range [][]Item{a.Decisions, a.NextSteps, a.OpenQuestions, a.Risks} {
		for _, i := range items {
			total += len(i.Text)
		}
	}
	for _, i := range a.ActionItems {
		total += len(i.Text)
	}
	return total
}
