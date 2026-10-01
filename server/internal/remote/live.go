package remote

import (
	"context"
	"encoding/binary"
	"errors"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"localflow/server/internal/speech"
)

// LiveScheduler runs one live-preview window on the dictation worker after
// every waiting dictation window (*speech.Scheduler). It returns
// speech.ErrBusy when the user already has a live window waiting.
type LiveScheduler interface {
	Live(ctx context.Context, user, channel int64, samples []float32) (speech.WindowResult, error)
}

// LiveConfig configures the live_window operation.
type LiveConfig struct {
	Scheduler LiveScheduler
	Clock     Clock
	Logger    *log.Logger
}

// Live runs live_window operations (Feature 018): one live-preview window of
// at most MaxLiveSamples s16le samples, recognized by the dictation worker,
// which already holds Parakeet (research R3). The worker accepts windows
// shorter than its 239,360-sample window and pads them itself, so flowd does
// not pad.
type Live struct {
	cfg      LiveConfig
	buffered atomic.Int64 // sample bytes held by live windows (tests)
}

// NewLive builds the operation; register Start under "live_window".
func NewLive(cfg LiveConfig) *Live {
	if cfg.Clock == nil {
		cfg.Clock = SystemClock
	}
	if cfg.Logger == nil {
		cfg.Logger = log.New(discard{}, "", 0)
	}
	return &Live{cfg: cfg}
}

// Start begins collecting a live_window's samples.
func (l *Live) Start(_ context.Context, c *Conn, m Message) (Operation, error) {
	start, ok := m.(LiveWindow)
	if !ok {
		return nil, invalid("not a live_window")
	}
	if err := checkAccess(c); err != nil {
		return nil, err
	}
	principal := c.Principal()
	ctx, cancel := context.WithCancel(context.Background())
	o := &liveOp{l: l, conn: c, op: start.Op, user: principal.UserID, device: principal.DeviceID, count: start.SampleCount,
		ctx: ctx, cancel: cancel, done: make(chan struct{}), started: l.cfg.Clock.Now(),
		samples: make([]float32, 0, start.SampleCount)}
	l.buffered.Add(int64(4 * start.SampleCount))
	return o, nil
}

// liveOp is one live window: collecting until sample_count samples have
// arrived, then running. The samples are freed when it ends for any reason.
type liveOp struct {
	l       *Live
	conn    *Conn
	op      int64
	user    int64
	device  int64
	count   int
	ctx     context.Context
	cancel  context.CancelFunc
	done    chan struct{}
	started time.Time

	mu      sync.Mutex
	samples []float32 // nil once ended
	running bool
	ended   bool
}

// endLocked frees the samples and closes done once, logging the outcome; it
// reports whether this call ended the operation.
func (o *liveOp) endLocked(code string) bool {
	if o.ended {
		return false
	}
	o.ended = true
	o.samples = nil
	o.l.buffered.Add(-int64(4 * o.count))
	close(o.done)
	o.l.cfg.Logger.Printf("remote live channel=%d user=%d device=%d op=%d samples=%d duration_ms=%d code=%s",
		o.conn.ID(), o.user, o.device, o.op, o.count, o.l.cfg.Clock.Now().Sub(o.started).Milliseconds(), code)
	return true
}

func (o *liveOp) refuseLocked(reason string) error {
	o.endLocked(string(CodeInvalidMessage))
	return invalid(reason)
}

func (o *liveOp) Samples(_ context.Context, payload []byte) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	switch {
	case o.ended:
		return nil
	case o.running || len(o.samples)+len(payload)/2 > o.count:
		return o.refuseLocked("more samples than sample_count")
	}
	for i := 0; i < len(payload); i += 2 {
		o.samples = append(o.samples, float32(int16(binary.LittleEndian.Uint16(payload[i:])))/32768)
	}
	if len(o.samples) == o.count {
		o.running = true
		go o.run(o.samples)
	}
	return nil
}

func (o *liveOp) run(samples []float32) {
	defer o.cancel()
	result, err := o.l.cfg.Scheduler.Live(o.ctx, o.user, int64(o.conn.ID()), samples)
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.ended {
		return
	}
	var message Message
	if err != nil {
		message = NewError(o.op, speechCode(err))
	} else if message, err = o.resultMessage(result); err != nil {
		message = NewError(o.op, CodeWorkerUnavailable)
	}
	code := "ok"
	if e, failed := message.(ErrorMessage); failed {
		code = string(e.Code)
	}
	o.endLocked(code)
	_ = o.conn.Send(context.Background(), message)
}

var errLiveWindow = errors.New("remote: worker window does not match its live window")

// resultMessage builds live_result from the worker's window object, decoded
// strictly as for dictation; a live window has no boost terms, so it may
// carry no hints.
func (o *liveOp) resultMessage(result speech.WindowResult) (Message, error) {
	var w workerWindow
	if err := strictDecode(result.Window, &w); err != nil {
		return nil, err
	}
	if w.SampleCount != o.count || len(w.BoostHints) != 0 {
		return nil, errLiveWindow
	}
	m := LiveResult{Op: o.op, Window: LiveWindowResult{Text: w.Text, Tokens: w.Tokens, Evidence: w.Evidence}, RecognitionMS: int64(result.RecognitionMS)}
	if _, err := EncodeMessage(m); err != nil {
		return nil, err
	}
	return m, nil
}

func (o *liveOp) Done() <-chan struct{} { return o.done }

// Control: a live window has no messages after live_window.
func (o *liveOp) Control(context.Context, Message) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.ended {
		return nil
	}
	return o.refuseLocked("message during a live window")
}

func (o *liveOp) Audio(context.Context, []byte) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.ended {
		return nil
	}
	return o.refuseLocked("f32le audio during a live window")
}

// Close cancels a waiting window (it leaves the scheduler's queue) and frees
// the samples.
func (o *liveOp) Close() {
	o.cancel()
	o.mu.Lock()
	o.endLocked("closed")
	o.mu.Unlock()
}
