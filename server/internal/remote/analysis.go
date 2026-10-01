package remote

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"localflow/server/internal/analysis"
)

// MaxAnalysesPerUser bounds one user's analysis ops across channels
// (Feature 018 research R8). The handler's own admission slots and its
// rewrite-first gate, shared with the HTTP route, still apply.
const MaxAnalysesPerUser = 1

// AnalysisRunner decodes and runs one analysis request (*analysis.Handler).
// Run uses the server's own backend, never a client-named one (research R9),
// and gives emit exactly one NDJSON line per event, ending with the result or
// error line.
type AnalysisRunner interface {
	DecodeRequest(body []byte) (*analysis.Request, error)
	Run(ctx context.Context, req *analysis.Request, emit func(line []byte) error) analysis.Code
}

// AnalysisConfig configures the analysis operation.
type AnalysisConfig struct {
	Runner AnalysisRunner
	Clock  Clock
	Logger *log.Logger
}

// Analyzer runs analysis operations on session channels: the request arrives
// as analysis_part fragments closed by analysis, and each event goes back as
// one analysis_event, or as analysis_event_part fragments closed by one when
// the line is too large for a control message.
type Analyzer struct {
	cfg      AnalysisConfig
	mu       sync.Mutex
	perUser  map[int64]int
	buffered atomic.Int64 // request bytes held in assembly buffers (tests)
}

// NewAnalyzer builds the operation; register Start under "analysis".
func NewAnalyzer(cfg AnalysisConfig) *Analyzer {
	if cfg.Clock == nil {
		cfg.Clock = SystemClock
	}
	if cfg.Logger == nil {
		cfg.Logger = log.New(discard{}, "", 0)
	}
	return &Analyzer{cfg: cfg, perUser: map[int64]int{}}
}

func (a *Analyzer) admit(user int64) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.perUser[user] >= MaxAnalysesPerUser {
		return false
	}
	a.perUser[user]++
	return true
}

func (a *Analyzer) release(user int64) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.perUser[user]--; a.perUser[user] <= 0 {
		delete(a.perUser, user)
	}
}

// inFlight counts admitted analyses (tests).
func (a *Analyzer) inFlight() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	n := 0
	for _, count := range a.perUser {
		n += count
	}
	return n
}

// analysisRequestCode maps an analysis request refusal to a channel code.
func analysisRequestCode(err error) ErrorCode {
	var refused *analysis.RequestError
	if errors.As(err, &refused) {
		switch refused.Code {
		case analysis.CodeUnsupportedVersion:
			return CodeUnsupportedVersion
		case analysis.CodeTooLarge:
			return CodeLimitExceeded
		}
	}
	return CodeInvalidMessage
}

// Start begins an analysis for its first analysis_part (index 0).
func (a *Analyzer) Start(_ context.Context, c *Conn, m Message) (Operation, error) {
	part, ok := m.(AnalysisPart)
	if !ok || part.Index != 0 {
		return nil, invalid("analysis does not start with fragment 0")
	}
	if err := checkAccess(c); err != nil {
		return nil, err
	}
	principal := c.Principal()
	if !a.admit(principal.UserID) {
		a.cfg.Logger.Printf("remote analysis channel=%d user=%d device=%d op=%d code=%s", c.ID(), principal.UserID, principal.DeviceID, part.Op, CodeBusy)
		return nil, &Error{CodeBusy, "analysis per-user bound"}
	}
	ctx, cancel := context.WithCancel(context.Background())
	o := &analysisOp{a: a, conn: c, op: part.Op, user: principal.UserID, device: principal.DeviceID,
		cancel: cancel, ctx: ctx, done: make(chan struct{}), started: a.cfg.Clock.Now()}
	o.appendPart(part.Data)
	return o, nil
}

// analysisOp is one analysis: assembling until the analysis message, then
// running. The terminal event is sent after done is closed and the user's
// slot is released, so the client may start its next operation on seeing it.
type analysisOp struct {
	a       *Analyzer
	conn    *Conn
	op      int64
	user    int64
	device  int64
	ctx     context.Context
	cancel  context.CancelFunc
	done    chan struct{}
	started time.Time
	release sync.Once

	mu      sync.Mutex
	ended   bool
	running bool
	body    []byte // the request so far; nil once running or ended
	parts   int
	bytes   int
}

var errAnalysisEnded = errors.New("remote: analysis operation ended")

// appendPart adds one fragment; the caller has checked the total.
func (o *analysisOp) appendPart(data string) {
	o.body = append(o.body, data...)
	o.parts++
	o.bytes += len(data)
	o.a.buffered.Add(int64(len(data)))
}

// freeLocked drops the assembly buffer.
func (o *analysisOp) freeLocked() {
	o.a.buffered.Add(-int64(len(o.body)))
	o.body = nil
}

func (o *analysisOp) Control(_ context.Context, m Message) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.ended {
		return nil
	}
	if o.running {
		return invalid("message during a running analysis")
	}
	switch m := m.(type) {
	case AnalysisPart:
		if m.Index != o.parts {
			return invalid("analysis fragment out of order")
		}
		if len(o.body)+len(m.Data) > MaxAnalysisBytes {
			return &Error{CodeLimitExceeded, "analysis request over 262,144 bytes"}
		}
		o.appendPart(m.Data)
		return nil
	case Analysis:
		sum := sha256.Sum256(o.body)
		if m.Parts != o.parts || m.Bytes != len(o.body) || m.SHA256 != hex.EncodeToString(sum[:]) {
			return invalid("analysis parts, bytes or sha256 mismatch")
		}
		req, err := o.a.cfg.Runner.DecodeRequest(o.body)
		o.freeLocked()
		if err != nil {
			return &Error{analysisRequestCode(err), "analysis request refused"}
		}
		o.running = true
		go o.run(req)
		return nil
	default:
		return invalid("unexpected message during an analysis")
	}
}

func (o *analysisOp) run(req *analysis.Request) {
	defer o.cancel()
	defer o.releaseSlot()
	code := o.a.cfg.Runner.Run(o.ctx, req, o.emit)
	outcome := string(code)
	if code == "" {
		outcome = "ok"
	}
	o.finish(outcome)
}

func (o *analysisOp) releaseSlot() { o.release.Do(func() { o.a.release(o.user) }) }

// endLocked closes done once and reports whether this call did.
func (o *analysisOp) endLocked() bool {
	if o.ended {
		return false
	}
	o.ended = true
	o.freeLocked()
	close(o.done)
	return true
}

// finish logs the operation: IDs, sizes, duration and the outcome only.
func (o *analysisOp) finish(code string) {
	o.mu.Lock()
	o.endLocked()
	o.mu.Unlock()
	o.a.cfg.Logger.Printf("remote analysis channel=%d user=%d device=%d op=%d parts=%d bytes=%d duration_ms=%d code=%s",
		o.conn.ID(), o.user, o.device, o.op, o.parts, o.bytes, o.a.cfg.Clock.Now().Sub(o.started).Milliseconds(), code)
}

// emit relays one NDJSON line as analysis_event messages. The op ends with
// the result or error event.
func (o *analysisOp) emit(line []byte) error {
	line = bytes.TrimSuffix(line, []byte("\n"))
	var kind struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(line, &kind) != nil {
		return o.fail(CodeInternal)
	}
	messages, err := eventMessages(o.op, line)
	if err != nil {
		return o.fail(CodeOf(err))
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.ended {
		return errAnalysisEnded
	}
	for i, m := range messages {
		if i == len(messages)-1 && (kind.Type == "result" || kind.Type == "error") {
			o.releaseSlot()
			o.endLocked()
		}
		if err := o.conn.Send(context.Background(), m); err != nil {
			return err
		}
	}
	return nil
}

// eventMessages is line as one inline analysis_event or, when that is too
// large for a control message, as analysis_event_part fragments of at most
// MaxAnalysisPartBytes cut on rune boundaries (halved while JSON escaping
// still makes one too large) closed by analysis_event with parts and the
// SHA-256 of line.
func eventMessages(op int64, line []byte) ([]Message, error) {
	inline := AnalysisEvent{Op: op, Event: json.RawMessage(line)}
	if _, err := EncodeMessage(inline); err == nil {
		return []Message{inline}, nil
	}
	var out []Message
	for rest := line; len(rest) > 0; {
		if len(out) == MaxAnalysisParts {
			return nil, &Error{CodeInternal, "analysis event in too many fragments"}
		}
		for n := min(len(rest), MaxAnalysisPartBytes); ; n /= 2 {
			for n > 0 && n < len(rest) && !utf8.RuneStart(rest[n]) {
				n--
			}
			if n == 0 {
				_, n = utf8.DecodeRune(rest)
			}
			part := AnalysisEventPart{Op: op, Index: len(out), Data: string(rest[:n])}
			if _, err := EncodeMessage(part); err == nil {
				out, rest = append(out, part), rest[n:]
				break
			}
		}
	}
	sum := sha256.Sum256(line)
	return append(out, AnalysisEvent{Op: op, Parts: len(out), SHA256: hex.EncodeToString(sum[:])}), nil
}

// fail ends the operation with error{op, code}.
func (o *analysisOp) fail(code ErrorCode) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.endLocked() {
		_ = o.conn.Send(context.Background(), NewError(o.op, code))
	}
	return errAnalysisEnded
}

func (o *analysisOp) Done() <-chan struct{} { return o.done }

// Audio: no f32le frame belongs to an analysis. Not being a SampleCollector,
// an s16le frame ends it the same way.
func (o *analysisOp) Audio(context.Context, []byte) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.ended {
		return nil
	}
	return invalid("audio during an analysis")
}

// Close cancels the analysis and frees its buffer; the user's slot is
// released here while assembling, or when Run returns.
func (o *analysisOp) Close() {
	o.cancel()
	o.mu.Lock()
	running := o.running
	o.endLocked()
	o.mu.Unlock()
	if !running {
		o.releaseSlot()
	}
}
