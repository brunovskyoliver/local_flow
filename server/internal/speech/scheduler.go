package speech

import (
	"context"
	"errors"
	"io"
	"log"
	"sync"
	"time"
)

// Scheduler bounds (research R11).
const (
	// MaxWaitingPerUser is the number of window jobs a user may have waiting
	// for the worker, not counting the one running.
	MaxWaitingPerUser = 2
	// MaxSessionWindows caps the windows of one session. A session of at
	// most 2,880,000 + 16,000 samples needs 13 windows of 239,360.
	MaxSessionWindows = 16
)

var (
	// ErrBusy ends a session whose user already has MaxWaitingPerUser
	// windows waiting. Clients see busy.
	ErrBusy = errors.New("speech: too many windows waiting")
	// ErrCancelled is returned by Submit after Cancel.
	ErrCancelled = errors.New("speech: session cancelled")
	// ErrOutOfOrder rejects a window whose index is not the next one.
	ErrOutOfOrder = errors.New("speech: window out of order")
	// ErrTooManyWindows rejects a window past MaxSessionWindows.
	ErrTooManyWindows = errors.New("speech: too many windows in session")
)

// Window is one recognition window of a dictation session.
type Window struct {
	Index       int
	SampleStart int
	Samples     []float32
	Boost       *Boost
}

// Outcome is one window's answer. Err is nil on success; otherwise the
// outcome is the session's last: ErrBusy, ErrWorkerUnavailable, a
// *WorkerError or ErrInvalidRecognition.
type Outcome struct {
	Index       int
	SampleStart int
	SampleCount int
	Result      WindowResult
	Err         error
}

// Progress says whether a session has work at the worker, for the progress
// message.
type Progress string

const (
	ProgressIdle        Progress = ""
	ProgressQueued      Progress = "queued"
	ProgressRecognizing Progress = "recognizing"
)

// SchedulerConfig configures a Scheduler.
type SchedulerConfig struct {
	// Recognizer runs the jobs, one at a time; normally the Supervisor.
	Recognizer Recognizer
	// Logger receives content-free lines: user, channel and window IDs,
	// sample counts, durations, queue depth and codes.
	Logger *log.Logger
}

// Scheduler sends window jobs to the worker one at a time. Each user has a
// queue of at most MaxWaitingPerUser waiting windows, and users with waiting
// windows are served round-robin, so with N users releasing together a user's
// tail window waits behind at most one window from each other user. Rewrites
// wait for WaitForNoDictationWindows before starting.
type Scheduler struct {
	c    SchedulerConfig
	wake chan struct{}

	mu      sync.Mutex
	queues  map[int64][]*job // waiting jobs per user, FIFO
	ring    []int64          // users with waiting jobs, in service order
	waiting int
	idle    chan struct{} // closed while no window waits
	closed  bool          // Run has returned
}

type job struct {
	session  *Session
	w        Window
	queuedAt time.Time
}

// NewScheduler returns a scheduler; call Run to start dispatching.
func NewScheduler(c SchedulerConfig) *Scheduler {
	if c.Logger == nil {
		c.Logger = log.New(io.Discard, "", 0)
	}
	idle := make(chan struct{})
	close(idle)
	return &Scheduler{c: c, wake: make(chan struct{}, 1), queues: map[int64][]*job{}, idle: idle}
}

// Session is one dictation's view of the scheduler. Its methods are safe for
// concurrent use.
type Session struct {
	s       *Scheduler
	user    int64
	channel int64
	results chan Outcome
	next    int   // next window index to submit
	queued  int   // windows waiting
	running bool  // a window is at the worker
	err     error // set once the session has ended
}

// Open starts a session for a user on a channel. The IDs are used for
// fairness and logs only.
func (s *Scheduler) Open(user, channel int64) *Session {
	return &Session{s: s, user: user, channel: channel, results: make(chan Outcome, MaxSessionWindows+1)}
}

// Results delivers the session's outcomes in window index order. After an
// outcome with an error, or after Cancel, the channel is closed.
func (x *Session) Results() <-chan Outcome { return x.results }

// Submit queues the next window. Windows must be submitted in index order
// starting at 0. When the user already has MaxWaitingPerUser windows waiting,
// the session ends: Submit returns ErrBusy and Results delivers a final
// outcome with ErrBusy. After the session has ended Submit returns the reason.
func (x *Session) Submit(w Window) error {
	s := x.s
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case x.err != nil:
		return x.err
	case s.closed:
		return ErrWorkerUnavailable
	case w.Index != x.next:
		return ErrOutOfOrder
	case len(w.Samples) < 1 || len(w.Samples) > MaxSampleCount:
		return ErrInvalidRecognition
	case w.Index >= MaxSessionWindows:
		return ErrTooManyWindows
	}
	if len(s.queues[x.user]) >= MaxWaitingPerUser {
		s.c.Logger.Printf("speech busy user=%d channel=%d window=%d waiting=%d", x.user, x.channel, w.Index, s.waiting)
		s.endLocked(x, ErrBusy, &Outcome{Index: w.Index, SampleStart: w.SampleStart, SampleCount: len(w.Samples), Err: ErrBusy})
		return ErrBusy
	}
	x.next++
	x.queued++
	if len(s.queues[x.user]) == 0 {
		s.ring = append(s.ring, x.user)
	}
	s.queues[x.user] = append(s.queues[x.user], &job{session: x, w: w, queuedAt: time.Now()})
	if s.waiting == 0 {
		s.idle = make(chan struct{})
	}
	s.waiting++
	select {
	case s.wake <- struct{}{}:
	default:
	}
	return nil
}

// Cancel ends the session: waiting windows are dropped, a running window's
// result is discarded, and Results is closed. Call it when the session ends
// for any reason; it does nothing after the session has ended.
func (x *Session) Cancel() {
	x.s.mu.Lock()
	defer x.s.mu.Unlock()
	x.s.endLocked(x, ErrCancelled, nil)
}

// Progress reports whether the session has a window at the worker or waiting.
func (x *Session) Progress() Progress {
	x.s.mu.Lock()
	defer x.s.mu.Unlock()
	switch {
	case x.err != nil:
		return ProgressIdle
	case x.running:
		return ProgressRecognizing
	case x.queued > 0:
		return ProgressQueued
	}
	return ProgressIdle
}

// Waiting is the number of windows waiting for the worker, across users.
func (s *Scheduler) Waiting() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.waiting
}

// WaitForNoDictationWindows returns once no dictation window is waiting for
// the worker (a running window does not count), or ctx is done. A rewrite
// calls it before starting so dictation windows run ahead of rewrites.
func (s *Scheduler) WaitForNoDictationWindows(ctx context.Context) error {
	s.mu.Lock()
	idle := s.idle
	s.mu.Unlock()
	select {
	case <-idle:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// endLocked ends a session once, dropping its waiting windows.
func (s *Scheduler) endLocked(x *Session, err error, final *Outcome) {
	if x.err != nil {
		return
	}
	x.err = err
	if x.queued > 0 {
		kept := s.queues[x.user][:0]
		for _, j := range s.queues[x.user] {
			if j.session != x {
				kept = append(kept, j)
			}
		}
		s.removeLocked(x.queued)
		x.queued = 0
		if len(kept) == 0 {
			delete(s.queues, x.user)
			s.leaveRingLocked(x.user)
		} else {
			s.queues[x.user] = kept
		}
	}
	if final != nil {
		x.results <- *final
	}
	close(x.results)
}

func (s *Scheduler) removeLocked(n int) {
	s.waiting -= n
	if s.waiting == 0 {
		close(s.idle)
	}
}

// leaveRingLocked removes a user whose queue emptied, so a later submission
// rejoins at the back instead of holding two turns per round.
func (s *Scheduler) leaveRingLocked(user int64) {
	for i, u := range s.ring {
		if u == user {
			s.ring = append(s.ring[:i], s.ring[i+1:]...)
			return
		}
	}
}

// pickLocked takes the head job of the next user in the ring.
func (s *Scheduler) pickLocked() *job {
	// Invariant: a user is in the ring once exactly when their queue is not
	// empty.
	if len(s.ring) > 0 {
		user := s.ring[0]
		s.ring = s.ring[1:]
		q := s.queues[user]
		j := q[0]
		if len(q) == 1 {
			delete(s.queues, user)
		} else {
			s.queues[user] = q[1:]
			s.ring = append(s.ring, user)
		}
		s.removeLocked(1)
		j.session.queued--
		j.session.running = true
		return j
	}
	return nil
}

// Run dispatches jobs until ctx is done. On return every waiting window is
// answered with ErrWorkerUnavailable and later submissions are refused.
func (s *Scheduler) Run(ctx context.Context) {
	defer func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.closed = true
		s.failWaitingLocked(ErrWorkerUnavailable)
	}()
	for {
		s.mu.Lock()
		j := s.pickLocked()
		s.mu.Unlock()
		if j == nil {
			select {
			case <-s.wake:
				continue
			case <-ctx.Done():
				return
			}
		}
		if ctx.Err() != nil {
			s.mu.Lock()
			j.session.running = false
			s.endLocked(j.session, ErrWorkerUnavailable, &Outcome{Index: j.w.Index, SampleStart: j.w.SampleStart, SampleCount: len(j.w.Samples), Err: ErrWorkerUnavailable})
			s.mu.Unlock()
			return
		}
		s.run(ctx, j)
	}
}

func (s *Scheduler) run(ctx context.Context, j *job) {
	started := time.Now()
	result, err := s.c.Recognizer.Recognize(ctx, Recognition{Samples: j.w.Samples, Boost: j.w.Boost})
	s.mu.Lock()
	defer s.mu.Unlock()
	x := j.session
	x.running = false
	code := "ok"
	out := Outcome{Index: j.w.Index, SampleStart: j.w.SampleStart, SampleCount: len(j.w.Samples), Result: result, Err: err}
	switch {
	case x.err != nil:
		code = "discarded"
	case err == nil:
		x.results <- out
	default:
		code = errorCode(err)
		if errors.Is(err, ErrWorkerUnavailable) || errors.Is(err, context.Canceled) {
			// The worker is gone: every waiting window of every session
			// gets worker_unavailable.
			out.Err = ErrWorkerUnavailable
			s.endLocked(x, ErrWorkerUnavailable, &out)
			s.failWaitingLocked(ErrWorkerUnavailable)
		} else {
			s.endLocked(x, err, &out)
		}
	}
	s.c.Logger.Printf("speech window user=%d channel=%d window=%d samples=%d queue_ms=%d duration_ms=%d code=%s waiting=%d",
		x.user, x.channel, j.w.Index, len(j.w.Samples), started.Sub(j.queuedAt).Milliseconds(), time.Since(started).Milliseconds(), code, s.waiting)
}

// failWaitingLocked ends every session that has a waiting window, answering
// its first waiting window with err.
func (s *Scheduler) failWaitingLocked(err error) {
	var first []*job
	seen := map[*Session]bool{}
	for _, user := range s.ring {
		for _, j := range s.queues[user] {
			if !seen[j.session] {
				seen[j.session] = true
				first = append(first, j)
			}
		}
	}
	for _, j := range first {
		s.endLocked(j.session, err, &Outcome{Index: j.w.Index, SampleStart: j.w.SampleStart, SampleCount: len(j.w.Samples), Err: err})
	}
	s.ring = nil
}

func errorCode(err error) string {
	var workerErr *WorkerError
	switch {
	case errors.As(err, &workerErr):
		return workerErr.Code
	case errors.Is(err, ErrWorkerUnavailable), errors.Is(err, context.Canceled):
		return "worker_unavailable"
	case errors.Is(err, ErrInvalidRecognition), errors.Is(err, ErrHeaderTooLarge):
		return "invalid_job"
	}
	return "internal"
}
