package remote

import (
	"context"
	"encoding/binary"
	"errors"
	"log"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"localflow/server/internal/speech"
)

// Dictation bounds (research R11). Channels per device are bounded by the
// listener at the hello.
const (
	MaxDictationSessions        = 8
	MaxDictationSessionsPerUser = 1
	// ProgressInterval is the minimum spacing of progress messages.
	ProgressInterval = 500 * time.Millisecond
)

// SpeechSession is the part of a scheduler session (*speech.Session) the
// dictation operation uses.
type SpeechSession interface {
	TrySubmit(w speech.Window) (bool, error)
	Results() <-chan speech.Outcome
	Cancel()
	Progress() speech.Progress
}

// SpeechScheduler opens one scheduler session per dictation. Use
// SchedulerSessions for the real *speech.Scheduler, whose Open returns the
// concrete *speech.Session.
type SpeechScheduler interface {
	Open(user, channel int64) SpeechSession
}

// SchedulerSessions adapts a *speech.Scheduler to SpeechScheduler.
func SchedulerSessions(s *speech.Scheduler) SpeechScheduler { return schedulerSessions{s} }

type schedulerSessions struct{ s *speech.Scheduler }

func (a schedulerSessions) Open(user, channel int64) SpeechSession { return a.s.Open(user, channel) }

// ModelSource reports the ready worker's model identity (speech.Supervisor).
type ModelSource interface {
	Model() (speech.ModelIdentity, bool)
}

// DictationConfig configures the dictation operation.
type DictationConfig struct {
	Scheduler SpeechScheduler
	Models    ModelSource
	// Clock times progress messages; defaults to SystemClock. Use the
	// listener's clock.
	Clock Clock
	// Logger receives content-free lines: IDs, counts, durations and codes.
	Logger *log.Logger
	// DebugBusy answers every dictation_start with busy (--debug-busy,
	// debug builds only).
	DebugBusy bool
}

// Dictation runs dictation_start operations on session channels and holds the
// server-wide session bounds.
type Dictation struct {
	cfg       DictationConfig
	debugBusy atomic.Bool

	mu      sync.Mutex
	total   int
	perUser map[int64]int
	live    map[*dictationOp]struct{}
}

// NewDictation builds the operation; register Start under "dictation_start".
func NewDictation(cfg DictationConfig) *Dictation {
	if cfg.Clock == nil {
		cfg.Clock = SystemClock
	}
	if cfg.Logger == nil {
		cfg.Logger = log.New(discard{}, "", 0)
	}
	d := &Dictation{cfg: cfg, perUser: map[int64]int{}, live: map[*dictationOp]struct{}{}}
	d.debugBusy.Store(cfg.DebugBusy)
	return d
}

// checkAccess refuses an operation once the hello's access token has expired
// by the server clock.
func checkAccess(c *Conn) error {
	if c.Purpose() != PurposeSession || c.Principal().DeviceID == 0 {
		return invalid("operation needs a session channel")
	}
	if expires := c.AccessExpiresAt(); !expires.IsZero() && !c.Now().Before(expires) {
		return &Error{CodeTokenExpired, "access token expired at operation start"}
	}
	return nil
}

func (d *Dictation) admit(user int64) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.total >= MaxDictationSessions || d.perUser[user] >= MaxDictationSessionsPerUser {
		return false
	}
	d.total++
	d.perUser[user]++
	return true
}

func (d *Dictation) release(o *dictationOp) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.total--
	if d.perUser[o.user]--; d.perUser[o.user] <= 0 {
		delete(d.perUser, o.user)
	}
	delete(d.live, o)
}

// sessions counts admitted dictations (tests).
func (d *Dictation) sessions() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.total
}

// liveOps lists running operations (tests).
func (d *Dictation) liveOps() []*dictationOp {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := make([]*dictationOp, 0, len(d.live))
	for o := range d.live {
		out = append(out, o)
	}
	return out
}

// Start begins a dictation for a dictation_start message.
func (d *Dictation) Start(ctx context.Context, c *Conn, m Message) (Operation, error) {
	start, ok := m.(DictationStart)
	if !ok {
		return nil, invalid("not a dictation_start")
	}
	if err := checkAccess(c); err != nil {
		return nil, err
	}
	principal := c.Principal()
	refuse := func(code ErrorCode, reason string) (Operation, error) {
		d.cfg.Logger.Printf("remote dictation channel=%d user=%d device=%d op=%d code=%s",
			c.ID(), principal.UserID, principal.DeviceID, start.Op, code)
		return nil, &Error{code, reason}
	}
	if d.debugBusy.Load() {
		return refuse(CodeBusy, "debug busy")
	}
	model, ready := d.cfg.Models.Model()
	if !ready {
		return refuse(CodeWorkerUnavailable, "worker not ready")
	}
	if !d.admit(principal.UserID) {
		return refuse(CodeBusy, "dictation session bound")
	}
	o := &dictationOp{
		d: d, conn: c, op: start.Op, user: principal.UserID, device: principal.DeviceID,
		started: d.cfg.Clock.Now(), done: make(chan struct{}), terms: map[BoostTerm]bool{},
	}
	if start.Boost != nil {
		boost := &speech.Boost{Terms: make([]speech.BoostTerm, 0, len(start.Boost.Terms)), Governed: append([]string{}, start.Boost.Governed...)}
		for _, term := range start.Boost.Terms {
			boost.Terms = append(boost.Terms, speech.BoostTerm{EntryID: term.EntryID, Canonical: term.Canonical})
			o.terms[term] = true
		}
		o.boost = boost
	}
	d.mu.Lock()
	d.live[o] = struct{}{}
	d.mu.Unlock()
	o.session = d.cfg.Scheduler.Open(principal.UserID, int64(c.ID()))
	accepted := DictationAccepted{Op: start.Op, WindowSamples: WindowSamples, Model: ModelIdentity{
		Engine: model.Engine, ModelID: model.ModelID, ModelRevision: model.ModelRevision, ManifestHash: model.ManifestHash,
		SDK: model.SDK, Booster: model.Booster, WorkerBuild: model.WorkerBuild,
	}}
	if _, err := EncodeMessage(accepted); err != nil {
		o.Close()
		return refuse(CodeWorkerUnavailable, "worker model identity out of bounds")
	}
	if err := c.Send(ctx, accepted); err != nil {
		o.Close()
		return nil, err
	}
	o.mu.Lock()
	if !o.terminated {
		o.progress = d.cfg.Clock.AfterFunc(ProgressInterval, o.tick)
	}
	o.mu.Unlock()
	go o.relay()
	return o, nil
}

// dictationOp is one running dictation. Every field below mu is guarded by
// it. Messages are queued under mu and written by one sender goroutine
// outside it, so a slow client never holds mu while the channel's reader
// needs it for the next audio frame. The terminal message is queued last and
// nothing of the session is queued after it.
type dictationOp struct {
	d       *Dictation
	conn    *Conn
	op      int64
	user    int64
	device  int64
	boost   *speech.Boost
	terms   map[BoostTerm]bool // the session's own terms, for boost hints
	session SpeechSession
	started time.Time
	done    chan struct{}

	mu         sync.Mutex
	buffer     []float32   // samples after the last full window; < one window
	held       [][]float32 // cut windows the scheduler had no room for yet
	samples    int         // samples received
	counts     []int       // sample count of each submitted window
	delivered  int         // window_results sent
	ended      bool        // dictation_end received
	endedAt    time.Time
	terminated bool
	progress   Timer
	outbox     []Message // written in order by send
	sending    bool
	closeOnce  sync.Once
}

func (o *dictationOp) Done() <-chan struct{} { return o.done }

// Close releases everything the operation holds; the listener calls it once
// when the operation ends for any reason, including the channel closing.
func (o *dictationOp) Close() {
	o.closeOnce.Do(func() {
		o.mu.Lock()
		o.terminateLocked("closed")
		o.mu.Unlock()
	})
}

// terminateLocked ends the operation once: it stops progress, cancels the
// scheduler session (dropping queued windows and discarding a running
// result), frees the buffer, releases the session bounds and closes done. It
// reports whether this call ended it.
func (o *dictationOp) terminateLocked(code string) bool {
	if o.terminated {
		return false
	}
	o.terminated = true
	if o.progress != nil {
		o.progress.Stop()
		o.progress = nil
	}
	if o.session != nil {
		o.session.Cancel()
	}
	o.buffer = nil
	o.held = nil
	if o.d != nil {
		o.d.release(o)
		now := o.d.cfg.Clock.Now()
		releaseMS := int64(-1)
		if o.ended {
			releaseMS = now.Sub(o.endedAt).Milliseconds()
		}
		o.d.cfg.Logger.Printf("remote dictation channel=%d user=%d device=%d op=%d windows=%d delivered=%d samples=%d duration_ms=%d release_ms=%d code=%s",
			o.conn.ID(), o.user, o.device, o.op, len(o.counts), o.delivered, o.samples, now.Sub(o.started).Milliseconds(), releaseMS, code)
	}
	close(o.done)
	return true
}

// failLocked ends the operation with code, sending error{op, code} itself. Used by
// the relay and timers; Control and Audio return the *Error instead.
func (o *dictationOp) failLocked(code ErrorCode) {
	if o.terminateLocked(string(code)) {
		o.sendLocked(NewError(o.op, code))
	}
}

// refuseLocked ends the operation and returns the *Error the listener sends.
// Results still queued are dropped so they do not follow that error.
func (o *dictationOp) refuseLocked(code ErrorCode, reason string) error {
	o.terminateLocked(string(code))
	o.outbox = nil
	return &Error{code, reason}
}

// sendLocked queues m for the sender goroutine, starting it if needed.
func (o *dictationOp) sendLocked(m Message) {
	o.outbox = append(o.outbox, m)
	if !o.sending {
		o.sending = true
		go o.send()
	}
}

// send writes queued messages in order, without holding mu during a write. A
// failed write ends the operation and drops the rest.
func (o *dictationOp) send() {
	for {
		o.mu.Lock()
		if len(o.outbox) == 0 {
			o.sending = false
			o.mu.Unlock()
			return
		}
		m := o.outbox[0]
		o.outbox = o.outbox[1:]
		o.mu.Unlock()
		if err := o.conn.Send(context.Background(), m); err != nil {
			o.mu.Lock()
			o.outbox = nil
			o.sending = false
			o.terminateLocked("closed")
			o.mu.Unlock()
			return
		}
	}
}

func (o *dictationOp) Audio(_ context.Context, payload []byte) error {
	n := len(payload) / 4
	if len(payload)%4 != 0 || n < 1 {
		return invalid("audio payload not whole samples")
	}
	if n > MaxAudioSamples {
		return &Error{CodeLimitExceeded, "audio frame over 16,000 samples"}
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	switch {
	case o.terminated:
		// Ended by the server (an error already went out); frames the
		// client sent before it saw that are dropped.
		return nil
	case o.ended:
		return o.refuseLocked(CodeInvalidMessage, "audio after dictation_end")
	case o.samples+n > MaxSessionSamples:
		return o.refuseLocked(CodeLimitExceeded, "session over 2,880,000 + 16,000 samples")
	}
	if o.buffer == nil {
		o.buffer = make([]float32, 0, WindowSamples+MaxAudioSamples)
	}
	for i := range n {
		o.buffer = append(o.buffer, math.Float32frombits(binary.LittleEndian.Uint32(payload[4*i:])))
	}
	o.samples += n
	for len(o.buffer) >= WindowSamples {
		window := make([]float32, WindowSamples)
		copy(window, o.buffer)
		o.buffer = o.buffer[:copy(o.buffer, o.buffer[WindowSamples:])]
		o.held = append(o.held, window)
	}
	return o.submitHeldLocked()
}

// submitHeldLocked hands held windows to the scheduler while the user's
// queue has room, ending the operation on refusal. Windows left over wait for
// the next result, which frees a place. MaxSessionSamples bounds what is
// held.
func (o *dictationOp) submitHeldLocked() error {
	for len(o.held) > 0 {
		index := len(o.counts)
		samples := o.held[0]
		queued, err := o.session.TrySubmit(speech.Window{Index: index, SampleStart: index * WindowSamples, Samples: samples, Boost: o.boost})
		if err != nil {
			return o.refuseLocked(speechCode(err), "window refused by the scheduler")
		}
		if !queued {
			return nil
		}
		o.held[0] = nil
		o.held = o.held[1:]
		o.counts = append(o.counts, len(samples))
	}
	return nil
}

func (o *dictationOp) Control(_ context.Context, m Message) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.terminated {
		return nil
	}
	switch m := m.(type) {
	case DictationEnd:
		if o.ended {
			return o.refuseLocked(CodeInvalidMessage, "second dictation_end")
		}
		if m.TotalSamples != int64(o.samples) {
			return o.refuseLocked(CodeInvalidMessage, "total_samples mismatch")
		}
		o.ended, o.endedAt = true, o.d.cfg.Clock.Now()
		if len(o.buffer) > 0 {
			o.held = append(o.held, append([]float32(nil), o.buffer...))
		}
		o.buffer = nil
		if err := o.submitHeldLocked(); err != nil {
			return err
		}
		o.completeIfDoneLocked()
		return nil
	case DictationCancel:
		if o.terminateLocked("cancelled") {
			o.outbox = nil
			o.sendLocked(Cancelled{Op: o.op})
		}
		return nil
	}
	return o.refuseLocked(CodeInvalidMessage, "unexpected message during dictation")
}

// completeIfDoneLocked sends dictation_complete once every window of an ended
// session has been answered.
func (o *dictationOp) completeIfDoneLocked() {
	if o.ended && len(o.held) == 0 && o.delivered == len(o.counts) && o.terminateLocked("ok") {
		o.sendLocked(DictationComplete{Op: o.op, Windows: o.delivered})
	}
}

// tick sends progress while a window is queued or running, then re-arms. It
// skips a beat while earlier messages are still being written.
func (o *dictationOp) tick() {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.terminated {
		return
	}
	if state := o.session.Progress(); state != speech.ProgressIdle && len(o.outbox) == 0 {
		o.sendLocked(Progress{Op: o.op, State: string(state)})
	}
	o.progress = o.d.cfg.Clock.AfterFunc(ProgressInterval, o.tick)
}

// relay turns the session's outcomes into window_result messages in index
// order, ending the operation on the first failure.
func (o *dictationOp) relay() {
	for outcome := range o.session.Results() {
		o.mu.Lock()
		if o.terminated {
			o.mu.Unlock()
			return
		}
		if outcome.Err != nil {
			o.failLocked(speechCode(outcome.Err))
			o.mu.Unlock()
			return
		}
		result, err := o.windowResultLocked(outcome)
		if err != nil {
			o.d.cfg.Logger.Printf("remote dictation channel=%d op=%d window=%d event=worker_window_refused", o.conn.ID(), o.op, outcome.Index)
			o.failLocked(CodeWorkerUnavailable)
			o.mu.Unlock()
			return
		}
		o.sendLocked(result)
		o.delivered++
		// The result freed a place in the user's queue.
		if err := o.submitHeldLocked(); err != nil {
			// refuseLocked dropped the queued result; the error goes alone.
			var coded *Error
			errors.As(err, &coded)
			o.sendLocked(NewError(o.op, coded.Code))
			o.mu.Unlock()
			return
		}
		o.completeIfDoneLocked()
		o.mu.Unlock()
	}
}

// workerWindow is the worker's window object: the window_result fields
// without op, index and sample_start (speech-worker-ipc.md). It is decoded
// strictly: unknown, missing or null fields are refused.
type workerWindow struct {
	SampleCount   int         `json:"sample_count"`
	Text          string      `json:"text"`
	Tokens        []Token     `json:"tokens"`
	Evidence      *Evidence   `json:"evidence,omitempty"`
	BoostHints    []BoostHint `json:"boost_hints"`
	RecognitionMS *int64      `json:"recognition_ms,omitempty"`
}

var errWorkerWindow = errors.New("remote: worker window does not match its job")

// windowResultLocked validates one outcome against the window this session
// submitted and builds its window_result. Boost hints must name the
// session's own terms, so a worker that leaked another job's terms is caught.
func (o *dictationOp) windowResultLocked(outcome speech.Outcome) (WindowResult, error) {
	index := o.delivered
	if outcome.Index != index || index >= len(o.counts) || outcome.SampleStart != index*WindowSamples ||
		outcome.SampleCount != o.counts[index] {
		return WindowResult{}, errWorkerWindow
	}
	var w workerWindow
	if err := strictDecode(outcome.Result.Window, &w); err != nil {
		return WindowResult{}, err
	}
	if w.SampleCount != o.counts[index] {
		return WindowResult{}, errWorkerWindow
	}
	for _, hint := range w.BoostHints {
		if !o.terms[BoostTerm{EntryID: hint.EntryID, Canonical: hint.Canonical}] {
			return WindowResult{}, errWorkerWindow
		}
	}
	result := WindowResult{
		Op: o.op, Index: index, SampleStart: outcome.SampleStart, SampleCount: w.SampleCount, Text: w.Text,
		Tokens: w.Tokens, Evidence: w.Evidence, BoostHints: w.BoostHints, RecognitionMS: int64(outcome.Result.RecognitionMS),
	}
	if _, err := EncodeMessage(result); err != nil {
		return WindowResult{}, err
	}
	return result, nil
}

// speechCode maps a scheduler or worker failure to a channel code.
func speechCode(err error) ErrorCode {
	var workerErr *speech.WorkerError
	switch {
	case errors.Is(err, speech.ErrBusy):
		return CodeBusy
	case errors.Is(err, speech.ErrWorkerUnavailable), errors.Is(err, context.Canceled):
		return CodeWorkerUnavailable
	case errors.Is(err, speech.ErrHeaderTooLarge):
		// A boost too large for the worker header; the control message
		// limit makes it unreachable in practice.
		return CodeInvalidMessage
	case errors.Is(err, speech.ErrTooManyWindows):
		return CodeLimitExceeded
	case errors.As(err, &workerErr):
		switch workerErr.Code {
		case speech.CodeModelUnavailable:
			return CodeWorkerUnavailable
		case speech.CodeInvalidAudio:
			return CodeInvalidMessage
		}
	}
	return CodeInternal
}

// Test accessors.
func (o *dictationOp) bufferLen() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return len(o.buffer)
}

func (o *dictationOp) bufferCap() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return cap(o.buffer)
}

func (o *dictationOp) received() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.samples
}
