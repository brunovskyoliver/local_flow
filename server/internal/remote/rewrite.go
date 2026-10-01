package remote

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"sync"
	"time"

	"localflow/server/internal/rewrite"
)

// MaxRewritesPerUser bounds one user's rewrites in flight across channels
// (research R11). The handler's own limit of rewrite.MaxConcurrentRequests,
// shared with the HTTP route, and its analysis gate still apply.
const MaxRewritesPerUser = 1

// RewriteRunner runs one decoded rewrite request (*rewrite.Handler). emit gets
// exactly one NDJSON line per event, ending with the result or error line.
type RewriteRunner interface {
	Run(ctx context.Context, req rewrite.Request, emit func(line []byte) error) rewrite.ErrorCode
}

// DictationWindows lets a rewrite wait until no dictation window is queued
// (*speech.Scheduler).
type DictationWindows interface {
	WaitForNoDictationWindows(ctx context.Context) error
}

// RewriteConfig configures the rewrite operation.
type RewriteConfig struct {
	// Runner is the same handler the HTTP route uses, so the in-flight limit
	// and the analysis gate are shared.
	Runner RewriteRunner
	// Windows, when set, delays each rewrite while dictation windows wait.
	Windows DictationWindows
	// Interactive, when set, is told when a rewrite is admitted; the
	// function it returns is called when the rewrite ends. Meeting jobs do
	// not start in between (speech.MeetingQueue.BeginInteractive).
	Interactive func() (end func())
	Clock       Clock
	Logger      *log.Logger
}

// Rewriter runs rewrite operations on session channels.
type Rewriter struct {
	cfg     RewriteConfig
	mu      sync.Mutex
	perUser map[int64]int
}

// NewRewriter builds the operation; register Start under "rewrite".
func NewRewriter(cfg RewriteConfig) *Rewriter {
	if cfg.Clock == nil {
		cfg.Clock = SystemClock
	}
	if cfg.Logger == nil {
		cfg.Logger = log.New(discard{}, "", 0)
	}
	return &Rewriter{cfg: cfg, perUser: map[int64]int{}}
}

func (r *Rewriter) admit(user int64) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.perUser[user] >= MaxRewritesPerUser {
		return false
	}
	r.perUser[user]++
	return true
}

func (r *Rewriter) release(user int64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.perUser[user]--; r.perUser[user] <= 0 {
		delete(r.perUser, user)
	}
}

// inFlight counts admitted rewrites (tests).
func (r *Rewriter) inFlight() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, count := range r.perUser {
		n += count
	}
	return n
}

// requestCode maps a rewrite request refusal to a channel code. The channel
// has already bounded the message at 65,536 bytes.
func requestCode(err error) ErrorCode {
	var refused *rewrite.RequestError
	if errors.As(err, &refused) {
		switch refused.Code {
		case rewrite.CodeUnsupportedVersion:
			return CodeUnsupportedVersion
		case rewrite.CodeTooLarge:
			return CodeLimitExceeded
		}
	}
	return CodeInvalidMessage
}

// Start begins a rewrite for a rewrite message. The request is decoded and
// validated by the rewrite protocol's own DecodeRequest.
func (r *Rewriter) Start(_ context.Context, c *Conn, m Message) (Operation, error) {
	message, ok := m.(Rewrite)
	if !ok {
		return nil, invalid("not a rewrite")
	}
	if err := checkAccess(c); err != nil {
		return nil, err
	}
	principal := c.Principal()
	req, err := rewrite.DecodeRequest(bytes.NewReader(message.Request))
	if err != nil {
		code := requestCode(err)
		r.cfg.Logger.Printf("remote rewrite channel=%d user=%d device=%d op=%d code=%s", c.ID(), principal.UserID, principal.DeviceID, message.Op, code)
		return nil, &Error{code, "rewrite request refused"}
	}
	if !r.admit(principal.UserID) {
		r.cfg.Logger.Printf("remote rewrite channel=%d user=%d device=%d op=%d code=%s", c.ID(), principal.UserID, principal.DeviceID, message.Op, CodeBusy)
		return nil, &Error{CodeBusy, "rewrite per-user bound"}
	}
	ctx, cancel := context.WithCancel(context.Background())
	o := &rewriteOp{r: r, conn: c, op: message.Op, user: principal.UserID, device: principal.DeviceID,
		cancel: cancel, done: make(chan struct{}), started: r.cfg.Clock.Now(), endInteractive: func() {}}
	if r.cfg.Interactive != nil {
		o.endInteractive = r.cfg.Interactive()
	}
	go o.run(ctx, req)
	return o, nil
}

// rewriteOp is one running rewrite. The terminal event is sent after done is
// closed and the user's slot is released, so the client may start its next
// operation as soon as it sees it.
type rewriteOp struct {
	r       *Rewriter
	conn    *Conn
	op      int64
	user    int64
	device  int64
	cancel  context.CancelFunc
	done    chan struct{}
	started time.Time
	release sync.Once
	// endInteractive ends the rewrite's interactive work.
	endInteractive func()

	mu    sync.Mutex
	ended bool
}

var errRewriteEnded = errors.New("remote: rewrite operation ended")

func (o *rewriteOp) run(ctx context.Context, req rewrite.Request) {
	defer o.cancel()
	defer o.releaseSlot()
	waited := o.r.cfg.Clock.Now()
	if o.r.cfg.Windows != nil {
		if err := o.r.cfg.Windows.WaitForNoDictationWindows(ctx); err != nil {
			o.finish("cancelled", waited)
			return
		}
	}
	waited = o.r.cfg.Clock.Now()
	code := o.r.cfg.Runner.Run(ctx, req, o.emit)
	outcome := string(code)
	if code == "" {
		outcome = "ok"
	}
	o.finish(outcome, waited)
}

func (o *rewriteOp) releaseSlot() {
	o.release.Do(func() {
		o.r.release(o.user)
		o.endInteractive()
	})
}

// endLocked closes done once and reports whether this call did.
func (o *rewriteOp) endLocked() bool {
	if o.ended {
		return false
	}
	o.ended = true
	close(o.done)
	return true
}

func (o *rewriteOp) finish(code string, waited time.Time) {
	o.mu.Lock()
	o.endLocked()
	o.mu.Unlock()
	now := o.r.cfg.Clock.Now()
	o.r.cfg.Logger.Printf("remote rewrite channel=%d user=%d device=%d op=%d wait_ms=%d duration_ms=%d code=%s",
		o.conn.ID(), o.user, o.device, o.op, waited.Sub(o.started).Milliseconds(), now.Sub(o.started).Milliseconds(), code)
}

// emit relays one NDJSON line as a rewrite_event carrying the line's JSON
// object.
func (o *rewriteOp) emit(line []byte) error {
	event := RewriteEvent{Op: o.op, Event: json.RawMessage(bytes.TrimSuffix(line, []byte("\n")))}
	var kind struct {
		Event string `json:"event"`
	}
	if json.Unmarshal(event.Event, &kind) != nil {
		return o.fail(CodeInternal)
	}
	if _, err := EncodeMessage(event); err != nil {
		// A result too large for one control message.
		return o.fail(CodeOf(err))
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.ended {
		return errRewriteEnded
	}
	if kind.Event == "result" || kind.Event == "error" {
		o.releaseSlot()
		o.endLocked()
	}
	return o.conn.Send(context.Background(), event)
}

// fail ends the operation with error{op, code}.
func (o *rewriteOp) fail(code ErrorCode) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.endLocked() {
		_ = o.conn.Send(context.Background(), NewError(o.op, code))
	}
	return errRewriteEnded
}

func (o *rewriteOp) Done() <-chan struct{} { return o.done }

// Control and Audio: nothing may be sent to a running rewrite.
func (o *rewriteOp) Control(context.Context, Message) error {
	return o.refuse()
}

func (o *rewriteOp) Audio(context.Context, []byte) error {
	return o.refuse()
}

func (o *rewriteOp) refuse() error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if !o.endLocked() {
		return nil
	}
	o.cancel()
	return invalid("frame during a rewrite")
}

// Close cancels the rewrite; the handler stops at its next step and the
// user's slot is released when Run returns.
func (o *rewriteOp) Close() {
	o.cancel()
	o.mu.Lock()
	o.endLocked()
	o.mu.Unlock()
}
