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
		Enabled:           true,
		Concurrency:       1,
		InputBytes:        98304,
		OutputBytes:       MaxLineBytes,
		ContextTokens:     32768,
		Timeout:           120 * time.Second,
		FirstTokenTimeout: 15 * time.Second,
		QueueWait:         30 * time.Second,
		Preempt:           true,
		OutputTokensChunk: 2048,
		OutputTokensFull:  3072,
	}
}

// OutputTokens is the backend max_tokens for a stage.
func (l Limits) OutputTokens(stage string) int {
	if stage == StageChunk {
		return l.OutputTokensChunk
	}
	return l.OutputTokensFull
}

// reserved instruction + schema + output tokens per the contract's estimate
// rule: input bytes / 3 + instruction, schema and output reservations.
const instructionReserveTokens = 900
const schemaReserveTokens = 600

// EstimateTokens approximates the context usage of one request.
func (l Limits) EstimateTokens(textBytes int, stage string) int {
	return textBytes/3 + instructionReserveTokens + schemaReserveTokens + l.OutputTokens(stage)
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
