package speech

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"os/exec"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// Supervisor defaults (research R11, FR-030).
const (
	DefaultJobDeadline      = 30 * time.Second
	DefaultUnavailableRetry = 60 * time.Second
	DefaultBackoffInitial   = time.Second
	DefaultBackoffMax       = 60 * time.Second
	// DefaultReadyTimeout bounds the model load before ready. A cold Core ML
	// compile can take minutes, so it is generous.
	DefaultReadyTimeout  = 5 * time.Minute
	DefaultShutdownGrace = 5 * time.Second
	maxWorkerLogLine     = 1024
)

// ErrWorkerUnavailable answers a job when the worker is not ready, crashed,
// timed out, sent a malformed frame or has no model. Clients see
// worker_unavailable.
var ErrWorkerUnavailable = errors.New("speech: worker unavailable")

// ErrInvalidRecognition rejects a job with no samples or more than one window.
var ErrInvalidRecognition = errors.New("speech: sample count out of range")

// WorkerError is the worker's own error answer to one job. The worker stays up.
type WorkerError struct{ Code string }

func (e *WorkerError) Error() string { return "speech: worker error " + e.Code }

// State is the supervisor's view of the worker process.
type State string

const (
	StateStarting    State = "starting"    // spawned, waiting for ready
	StateReady       State = "ready"       // accepting jobs
	StateUnavailable State = "unavailable" // worker reported no model; retried every 60 s
	StateRestarting  State = "restarting"  // failed; waiting out the backoff
	StateStopped     State = "stopped"     // Run returned
)

// Recognition is one window job as the worker sees it.
type Recognition struct {
	Samples []float32
	Boost   *Boost
}

// WindowResult is the worker's answer: its window object (the window_result
// fields without op, index and sample_start) and the recognition time.
type WindowResult struct {
	Window        json.RawMessage
	RecognitionMS int
}

// Recognizer runs one job at a time. Supervisor implements it; the scheduler
// depends only on this.
type Recognizer interface {
	Recognize(ctx context.Context, r Recognition) (WindowResult, error)
}

// Clock creates the supervisor's timers so tests can fire them.
type Clock interface {
	NewTimer(d time.Duration) Timer
}

// Timer is the part of time.Timer the supervisor uses.
type Timer interface {
	C() <-chan time.Time
	Stop() bool
}

type realClock struct{}
type realTimer struct{ t *time.Timer }

func (realClock) NewTimer(d time.Duration) Timer { return realTimer{time.NewTimer(d)} }
func (t realTimer) C() <-chan time.Time          { return t.t.C }
func (t realTimer) Stop() bool                   { return t.t.Stop() }

// RealClock returns the wall clock.
func RealClock() Clock { return realClock{} }

// SupervisorConfig configures the worker child process. Zero durations take
// the defaults; a negative ReadyTimeout disables the ready deadline.
type SupervisorConfig struct {
	// Command is the worker path and arguments, e.g.
	// [<flowd dir>/flowd-speech, serve, --models, <dir>].
	Command []string
	// Env is the worker's environment; nil inherits flowd's.
	Env []string
	// Logger receives the supervisor's content-free lines and the worker's
	// stderr lines, each prefixed "worker ".
	Logger *log.Logger
	Clock  Clock
	// OnState, when set, is called on every state change from the supervisor
	// goroutine. It must not block.
	OnState          func(State)
	JobDeadline      time.Duration
	UnavailableRetry time.Duration
	BackoffInitial   time.Duration
	BackoffMax       time.Duration
	ReadyTimeout     time.Duration
	ShutdownGrace    time.Duration
}

// Supervisor owns the speech worker process: it starts it, waits for ready,
// sends one job at a time, enforces the job deadline, and on any failure kills
// the process group and restarts it with backoff. flowd keeps serving
// throughout; jobs sent while the worker is not ready get ErrWorkerUnavailable.
type Supervisor struct {
	c       SupervisorConfig
	reqs    chan request
	stopped chan struct{}
	state   atomic.Value // State
	model   atomic.Pointer[ModelIdentity]
	nextJob uint64
}

type request struct {
	r     Recognition
	reply chan answer
}

type answer struct {
	result WindowResult
	err    error
}

// NewSupervisor applies the defaults. Call Run to start the worker.
func NewSupervisor(c SupervisorConfig) *Supervisor {
	if c.Logger == nil {
		c.Logger = log.New(io.Discard, "", 0)
	}
	if c.Clock == nil {
		c.Clock = RealClock()
	}
	defaults := []struct {
		d *time.Duration
		v time.Duration
	}{
		{&c.JobDeadline, DefaultJobDeadline}, {&c.UnavailableRetry, DefaultUnavailableRetry},
		{&c.BackoffInitial, DefaultBackoffInitial}, {&c.BackoffMax, DefaultBackoffMax},
		{&c.ReadyTimeout, DefaultReadyTimeout}, {&c.ShutdownGrace, DefaultShutdownGrace},
	}
	for _, d := range defaults {
		if *d.d == 0 {
			*d.d = d.v
		}
	}
	s := &Supervisor{c: c, reqs: make(chan request), stopped: make(chan struct{})}
	s.state.Store(StateStarting)
	return s
}

// State reports the worker state.
func (s *Supervisor) State() State { return s.state.Load().(State) }

// Model returns the identity from the current worker's ready message; ok is
// false unless the worker is ready.
func (s *Supervisor) Model() (ModelIdentity, bool) {
	m := s.model.Load()
	if m == nil {
		return ModelIdentity{}, false
	}
	return *m, true
}

func (s *Supervisor) setState(st State) {
	s.state.Store(st)
	s.c.Logger.Printf("speech worker_state=%s", st)
	if s.c.OnState != nil {
		s.c.OnState(st)
	}
}

// Recognize sends one job and waits for its answer. It returns
// ErrWorkerUnavailable at once when the worker is not ready, and when the
// worker fails while the job waits. Calls are serialized: a second call waits
// until the first is answered. ctx bounds only the wait to be sent; once sent,
// the job is answered by the worker, the deadline or a failure.
func (s *Supervisor) Recognize(ctx context.Context, r Recognition) (WindowResult, error) {
	if len(r.Samples) < 1 || len(r.Samples) > MaxSampleCount {
		return WindowResult{}, ErrInvalidRecognition
	}
	if s.State() != StateReady {
		return WindowResult{}, ErrWorkerUnavailable
	}
	req := request{r: r, reply: make(chan answer, 1)}
	select {
	case s.reqs <- req:
	case <-ctx.Done():
		return WindowResult{}, ctx.Err()
	case <-s.stopped:
		return WindowResult{}, ErrWorkerUnavailable
	}
	select {
	case a := <-req.reply:
		return a.result, a.err
	case <-s.stopped:
		return WindowResult{}, ErrWorkerUnavailable
	}
}

type runOutcome int

const (
	runFailed runOutcome = iota
	runUnavailable
	runStopped
)

// Run supervises the worker until ctx is done, then sends shutdown and returns
// once the process group is gone.
func (s *Supervisor) Run(ctx context.Context) {
	defer func() {
		s.setState(StateStopped)
		close(s.stopped)
	}()
	backoff := s.c.BackoffInitial
	for ctx.Err() == nil {
		switch s.runOnce(ctx, &backoff) {
		case runStopped:
			return
		case runUnavailable:
			s.setState(StateUnavailable)
			if !s.wait(ctx, s.c.UnavailableRetry) {
				return
			}
		case runFailed:
			s.setState(StateRestarting)
			delay := backoff
			backoff = min(2*backoff, s.c.BackoffMax)
			s.c.Logger.Printf("speech worker_restart_in_ms=%d", delay.Milliseconds())
			if !s.wait(ctx, delay) {
				return
			}
		}
	}
}

// wait answers jobs with ErrWorkerUnavailable until d passes or ctx is done.
func (s *Supervisor) wait(ctx context.Context, d time.Duration) bool {
	t := s.c.Clock.NewTimer(d)
	defer t.Stop()
	for {
		select {
		case <-t.C():
			return true
		case <-ctx.Done():
			return false
		case req := <-s.reqs:
			req.reply <- answer{err: ErrWorkerUnavailable}
		}
	}
}

func (s *Supervisor) fail(reason string) runOutcome {
	s.c.Logger.Printf("speech worker_failure=%s", reason)
	return runFailed
}

// runOnce starts one worker process and serves it until it fails, reports
// unavailable, or ctx is done.
func (s *Supervisor) runOnce(ctx context.Context, backoff *time.Duration) runOutcome {
	s.setState(StateStarting)
	p, err := s.spawn()
	if err != nil {
		return s.fail("spawn")
	}
	defer p.stop(s.c.Logger)
	defer s.model.Store(nil)

	var readyTimeout <-chan time.Time
	if s.c.ReadyTimeout > 0 {
		t := s.c.Clock.NewTimer(s.c.ReadyTimeout)
		defer t.Stop()
		readyTimeout = t.C()
	}
	for ready := false; !ready; {
		select {
		case ev := <-p.frames:
			if ev.err != nil {
				return s.fail(frameFailure(ev.err))
			}
			switch h := ev.frame.Header; h.Type {
			case TypeReady:
				model := *h.Model
				s.model.Store(&model)
				s.c.Logger.Printf("speech worker_ready engine=%.64s model_id=%.64s model_revision=%.64s booster=%.64s worker_build=%.64s", model.Engine, model.ModelID, model.ModelRevision, model.Booster, model.WorkerBuild)
				s.setState(StateReady)
				ready = true
			case TypeUnavailable:
				s.c.Logger.Printf("speech worker_unavailable reason=%.32s", h.Reason)
				return runUnavailable
			default:
				return s.fail("not_ready_first")
			}
		case <-readyTimeout:
			return s.fail("ready_timeout")
		case req := <-s.reqs:
			req.reply <- answer{err: ErrWorkerUnavailable}
		case <-ctx.Done():
			return runStopped
		}
	}
	for {
		select {
		case ev := <-p.frames:
			if ev.err != nil {
				return s.fail(frameFailure(ev.err))
			}
			if ev.frame.Header.Type != TypeState {
				return s.fail("unsolicited_" + ev.frame.Header.Type)
			}
			s.c.Logger.Printf("speech worker_runtime=%s", ev.frame.Header.State)
		case req := <-s.reqs:
			if o, done := s.job(ctx, p, req, backoff); done {
				return o
			}
		case <-ctx.Done():
			s.shutdown(p)
			return runStopped
		}
	}
}

// job sends one recognize and waits for its answer. done reports that the
// worker is gone and runOnce must return o.
func (s *Supervisor) job(ctx context.Context, p *process, req request, backoff *time.Duration) (o runOutcome, done bool) {
	s.nextJob++
	id := s.nextJob
	data, err := EncodeFrame(Header{Type: TypeRecognize, Job: id, SampleCount: len(req.r.Samples), Boost: req.r.Boost}, EncodeSamples(req.r.Samples))
	if err != nil {
		// Nothing was written; the worker is unaffected.
		req.reply <- answer{err: err}
		return 0, false
	}
	start := time.Now()
	unavailable := func(reason string) (runOutcome, bool) {
		s.c.Logger.Printf("speech job=%d samples=%d duration_ms=%d code=worker_unavailable", id, len(req.r.Samples), time.Since(start).Milliseconds())
		req.reply <- answer{err: ErrWorkerUnavailable}
		return s.fail(reason), true
	}
	// The write runs aside so a worker that stops reading cannot outlive the
	// deadline; stop closes stdin, which ends it.
	written := make(chan error, 1)
	go func() {
		_, err := p.stdin.Write(data)
		written <- err
	}()
	deadline := s.c.Clock.NewTimer(s.c.JobDeadline)
	defer deadline.Stop()
	var reply *answer
	code := ""
	for {
		if reply != nil && written == nil {
			s.c.Logger.Printf("speech job=%d samples=%d duration_ms=%d code=%s", id, len(req.r.Samples), time.Since(start).Milliseconds(), code)
			*backoff = s.c.BackoffInitial
			req.reply <- *reply
			return 0, false
		}
		select {
		case err := <-written:
			if err != nil {
				return unavailable("write")
			}
			written = nil
		case ev := <-p.frames:
			if ev.err != nil {
				return unavailable(frameFailure(ev.err))
			}
			h := ev.frame.Header
			switch {
			case h.Type == TypeState:
				s.c.Logger.Printf("speech worker_runtime=%s", h.State)
			case reply != nil || (h.Type != TypeResult && h.Type != TypeError):
				return unavailable("unsolicited_" + h.Type)
			case h.Job != id:
				return unavailable("wrong_job")
			case h.Type == TypeResult:
				reply, code = &answer{result: WindowResult{Window: h.Window, RecognitionMS: *h.RecognitionMS}}, "ok"
			default:
				reply, code = &answer{err: &WorkerError{Code: h.Code}}, h.Code
			}
		case <-deadline.C():
			return unavailable("deadline")
		case <-ctx.Done():
			req.reply <- answer{err: ErrWorkerUnavailable}
			return runStopped, true
		}
	}
}

// shutdown asks a ready worker to exit and waits up to the grace period.
func (s *Supervisor) shutdown(p *process) {
	if WriteFrame(p.stdin, Header{Type: TypeShutdown}, nil) != nil {
		return
	}
	grace := s.c.Clock.NewTimer(s.c.ShutdownGrace)
	defer grace.Stop()
	for {
		select {
		case ev := <-p.frames:
			if ev.err != nil {
				return
			}
		case <-grace.C():
			return
		}
	}
}

func frameFailure(err error) string {
	switch {
	case errors.Is(err, io.EOF):
		return "eof"
	case errors.Is(err, ErrMalformedFrame):
		return "malformed_frame"
	default:
		return "read"
	}
}

type frameEvent struct {
	frame Frame
	err   error
}

type process struct {
	cmd        *exec.Cmd
	stdin      io.WriteCloser
	frames     chan frameEvent
	quit       chan struct{}
	stdoutDone chan struct{}
	stderrDone chan struct{}
	stopOnce   sync.Once
}

func (s *Supervisor) spawn() (*process, error) {
	if len(s.c.Command) == 0 {
		return nil, errors.New("speech: no worker command")
	}
	cmd := exec.Command(s.c.Command[0], s.c.Command[1:]...)
	cmd.Env = s.c.Env
	// Its own process group, so a kill reaches anything the worker started.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	p := &process{cmd: cmd, stdin: stdin, frames: make(chan frameEvent, 8), quit: make(chan struct{}), stdoutDone: make(chan struct{}), stderrDone: make(chan struct{})}
	go func() {
		defer close(p.stdoutDone)
		r := bufio.NewReaderSize(stdout, 64*1024)
		for {
			f, err := ReadFrame(r)
			select {
			case p.frames <- frameEvent{f, err}:
			case <-p.quit:
				return
			}
			if err != nil {
				return
			}
		}
	}()
	go func() {
		defer close(p.stderrDone)
		copyWorkerLog(stderr, s.c.Logger)
	}()
	return p, nil
}

// copyWorkerLog copies stderr lines into the log with a "worker " prefix,
// truncating each at maxWorkerLogLine bytes.
func copyWorkerLog(r io.Reader, logger *log.Logger) {
	br := bufio.NewReaderSize(r, maxWorkerLogLine)
	for {
		line, err := br.ReadSlice('\n')
		if len(line) > 0 {
			text := string(line)
			if text[len(text)-1] == '\n' {
				text = text[:len(text)-1]
			}
			logger.Printf("worker %s", text)
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			// Drop the rest of an over-long line.
			for errors.Is(err, bufio.ErrBufferFull) {
				_, err = br.ReadSlice('\n')
			}
		}
		if err != nil && !errors.Is(err, bufio.ErrBufferFull) {
			return
		}
	}
}

// stop kills the whole process group, then reaps the worker. Safe to call
// more than once.
func (p *process) stop(logger *log.Logger) {
	p.stopOnce.Do(func() {
		_ = syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL)
		close(p.quit)
		_ = p.stdin.Close()
		// Keep the worker's last stderr lines; the pipe closes once the group
		// is gone.
		select {
		case <-p.stderrDone:
		case <-time.After(time.Second):
		}
		err := p.cmd.Wait()
		<-p.stdoutDone
		<-p.stderrDone
		status := "0"
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			status = exit.String()
		} else if err != nil {
			status = "unknown"
		}
		logger.Printf("speech worker_exit=%q", status)
	})
}
