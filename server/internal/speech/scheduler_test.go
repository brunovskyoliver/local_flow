package speech

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeRecognizer hands each job to the test, which answers it.
type fakeRecognizer struct {
	calls     chan *call
	active    atomic.Int32
	maxActive atomic.Int32
}

type call struct {
	r     Recognition
	reply chan answer
}

func newFakeRecognizer() *fakeRecognizer { return &fakeRecognizer{calls: make(chan *call, 64)} }

func (f *fakeRecognizer) Recognize(_ context.Context, r Recognition) (WindowResult, error) {
	n := f.active.Add(1)
	defer f.active.Add(-1)
	for {
		max := f.maxActive.Load()
		if n <= max || f.maxActive.CompareAndSwap(max, n) {
			break
		}
	}
	c := &call{r: r, reply: make(chan answer, 1)}
	f.calls <- c
	a := <-c.reply
	return a.result, a.err
}

func (f *fakeRecognizer) next(t *testing.T) *call {
	t.Helper()
	select {
	case c := <-f.calls:
		return c
	case <-time.After(5 * time.Second):
		t.Fatal("no job reached the worker")
		return nil
	}
}

func (f *fakeRecognizer) none(t *testing.T) {
	t.Helper()
	select {
	case c := <-f.calls:
		t.Fatalf("unexpected job %v", c.id())
	case <-time.After(20 * time.Millisecond):
	}
}

// Job identity rides in the first sample: user*100 + window index.
func id(user int64, index int) float32 { return float32(user*100 + int64(index)) }
func (c *call) id() int                { return int(c.r.Samples[0]) }
func (c *call) ok() {
	c.reply <- answer{result: WindowResult{Window: json.RawMessage(fmt.Sprintf(`{"id":%d}`, c.id())), RecognitionMS: 3}}
}
func (c *call) fail(err error) { c.reply <- answer{err: err} }

func startScheduler(t *testing.T) (*Scheduler, *fakeRecognizer, *syncBuffer) {
	t.Helper()
	f := newFakeRecognizer()
	logs := &syncBuffer{}
	s := NewScheduler(SchedulerConfig{Recognizer: f, Logger: log.New(logs, "", 0)})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.Run(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		// Unblock a job the test left running.
		for {
			select {
			case c := <-f.calls:
				c.fail(ErrWorkerUnavailable)
			case <-done:
				return
			}
		}
	})
	return s, f, logs
}

func window(user int64, index int) Window {
	return Window{Index: index, SampleStart: index * MaxSampleCount, Samples: []float32{id(user, index), 0, 0}, Boost: &Boost{Terms: []BoostTerm{{EntryID: "e", Canonical: "Secretterm"}}}}
}

func submit(t *testing.T, x *Session, user int64, index int) {
	t.Helper()
	if err := x.Submit(window(user, index)); err != nil {
		t.Fatalf("user %d window %d: %v", user, index, err)
	}
}

func outcome(t *testing.T, x *Session) (Outcome, bool) {
	t.Helper()
	select {
	case o, open := <-x.Results():
		return o, open
	case <-time.After(5 * time.Second):
		t.Fatal("no outcome")
		return Outcome{}, false
	}
}

func expectClosed(t *testing.T, x *Session) {
	t.Helper()
	if o, open := outcome(t, x); open {
		t.Fatalf("unexpected outcome %+v", o)
	}
}

func TestSchedulerResultsInIndexOrder(t *testing.T) {
	s, f, logs := startScheduler(t)
	x := s.Open(1, 10)
	submit(t, x, 1, 0)
	first := f.next(t)
	submit(t, x, 1, 1)
	submit(t, x, 1, 2)
	first.ok()
	for i := 1; i <= 2; i++ {
		f.next(t).ok()
	}
	for i := 0; i < 3; i++ {
		o, open := outcome(t, x)
		if !open || o.Err != nil || o.Index != i || o.SampleStart != i*MaxSampleCount || o.SampleCount != 3 || string(o.Result.Window) != fmt.Sprintf(`{"id":%d}`, 100+i) || o.Result.RecognitionMS != 3 {
			t.Fatalf("%+v", o)
		}
	}
	if f.maxActive.Load() != 1 {
		t.Fatal("more than one job at a time")
	}
	if err := x.Submit(window(1, 5)); !errors.Is(err, ErrOutOfOrder) {
		t.Fatal(err)
	}
	x.Cancel()
	line := logs.String()
	if !strings.Contains(line, "user=1 channel=10 window=2 samples=3") || strings.Contains(line, "Secretterm") {
		t.Fatal(line)
	}
}

func TestSchedulerOneJobAtATime(t *testing.T) {
	s, f, _ := startScheduler(t)
	var sessions []*Session
	for u := int64(1); u <= 4; u++ {
		x := s.Open(u, u)
		sessions = append(sessions, x)
		submit(t, x, u, 0)
	}
	for i := 0; i < 4; i++ {
		c := f.next(t)
		f.none(t)
		c.ok()
	}
	for _, x := range sessions {
		if o, _ := outcome(t, x); o.Err != nil {
			t.Fatal(o.Err)
		}
	}
	if f.maxActive.Load() != 1 {
		t.Fatal(f.maxActive.Load())
	}
}

func TestSchedulerOverflowEndsSessionWithBusy(t *testing.T) {
	s, f, _ := startScheduler(t)
	a, b := s.Open(1, 1), s.Open(2, 2)
	submit(t, a, 1, 0)
	running := f.next(t)
	submit(t, a, 1, 1)
	submit(t, a, 1, 2)
	if err := a.Submit(window(1, 3)); !errors.Is(err, ErrBusy) {
		t.Fatal(err)
	}
	if o, open := outcome(t, a); !open || !errors.Is(o.Err, ErrBusy) {
		t.Fatalf("%+v", o)
	}
	expectClosed(t, a)
	if err := a.Submit(window(1, 4)); !errors.Is(err, ErrBusy) {
		t.Fatal(err)
	}
	submit(t, b, 2, 0)
	running.ok()
	// a's waiting windows were dropped and its running result discarded.
	if c := f.next(t); c.id() != 200 {
		t.Fatal(c.id())
	} else {
		c.ok()
	}
	f.none(t)
	if a.Progress() != ProgressIdle {
		t.Fatal(a.Progress())
	}
	// The user may open a new session afterwards.
	a2 := s.Open(1, 1)
	submit(t, a2, 1, 0)
	f.next(t).ok()
	if o, _ := outcome(t, a2); o.Err != nil {
		t.Fatal(o.Err)
	}
}

func TestSchedulerRoundRobin(t *testing.T) {
	s, f, _ := startScheduler(t)
	a, b, c := s.Open(1, 1), s.Open(2, 2), s.Open(3, 3)
	submit(t, a, 1, 0)
	running := f.next(t)
	submit(t, a, 1, 1)
	submit(t, a, 1, 2)
	submit(t, b, 2, 0)
	submit(t, b, 2, 1)
	submit(t, c, 3, 0)
	running.ok()
	var order []int
	for i := 0; i < 5; i++ {
		j := f.next(t)
		order = append(order, j.id())
		j.ok()
	}
	if fmt.Sprint(order) != "[101 200 300 102 201]" {
		t.Fatal(order)
	}
}

func TestSchedulerRewriteWaitsForWaitingWindows(t *testing.T) {
	s, f, _ := startScheduler(t)
	if err := s.WaitForNoDictationWindows(context.Background()); err != nil {
		t.Fatal(err)
	}
	a := s.Open(1, 1)
	submit(t, a, 1, 0)
	running := f.next(t)
	// A running window does not hold rewrites back; a waiting one does.
	if err := s.WaitForNoDictationWindows(context.Background()); err != nil {
		t.Fatal(err)
	}
	submit(t, a, 1, 1)
	if s.Waiting() != 1 {
		t.Fatal(s.Waiting())
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if err := s.WaitForNoDictationWindows(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
	released := make(chan error, 1)
	go func() { released <- s.WaitForNoDictationWindows(context.Background()) }()
	select {
	case <-released:
		t.Fatal("rewrite started while a window waited")
	case <-time.After(20 * time.Millisecond):
	}
	running.ok()
	next := f.next(t)
	if err := <-released; err != nil {
		t.Fatal(err)
	}
	next.ok()
}

func TestSchedulerCancel(t *testing.T) {
	s, f, _ := startScheduler(t)
	a, b := s.Open(1, 1), s.Open(2, 2)
	submit(t, a, 1, 0)
	running := f.next(t)
	submit(t, a, 1, 1)
	submit(t, b, 2, 0)
	if a.Progress() != ProgressRecognizing || b.Progress() != ProgressQueued {
		t.Fatal(a.Progress(), b.Progress())
	}
	a.Cancel()
	a.Cancel()
	expectClosed(t, a)
	if a.Progress() != ProgressIdle {
		t.Fatal(a.Progress())
	}
	if err := a.Submit(window(1, 2)); !errors.Is(err, ErrCancelled) {
		t.Fatal(err)
	}
	running.ok()
	// Only b's window remains; a's queued window was dropped.
	c := f.next(t)
	if c.id() != 200 {
		t.Fatal(c.id())
	}
	if b.Progress() != ProgressRecognizing {
		t.Fatal(b.Progress())
	}
	c.ok()
	if o, _ := outcome(t, b); o.Err != nil || o.Index != 0 {
		t.Fatalf("%+v", o)
	}
	if b.Progress() != ProgressIdle {
		t.Fatal(b.Progress())
	}
	f.none(t)
}

func TestSchedulerWorkerUnavailableAnswersEveryWaitingJob(t *testing.T) {
	s, f, _ := startScheduler(t)
	a, b, c := s.Open(1, 1), s.Open(2, 2), s.Open(3, 3)
	submit(t, a, 1, 0)
	running := f.next(t)
	submit(t, a, 1, 1)
	submit(t, b, 2, 0)
	submit(t, b, 2, 1)
	running.fail(ErrWorkerUnavailable)
	for _, x := range []*Session{a, b} {
		o, open := outcome(t, x)
		if !open || !errors.Is(o.Err, ErrWorkerUnavailable) || o.Index != 0 {
			t.Fatalf("%+v", o)
		}
		expectClosed(t, x)
		if err := x.Submit(window(9, 9)); !errors.Is(err, ErrWorkerUnavailable) {
			t.Fatal(err)
		}
	}
	f.none(t)
	if s.Waiting() != 0 {
		t.Fatal(s.Waiting())
	}
	// c had nothing waiting; it keeps going once the worker is back.
	submit(t, c, 3, 0)
	f.next(t).ok()
	if o, _ := outcome(t, c); o.Err != nil {
		t.Fatal(o.Err)
	}
}

func TestSchedulerWorkerErrorEndsOnlyThatSession(t *testing.T) {
	s, f, _ := startScheduler(t)
	a, b := s.Open(1, 1), s.Open(2, 2)
	submit(t, a, 1, 0)
	running := f.next(t)
	submit(t, a, 1, 1)
	submit(t, b, 2, 0)
	running.fail(&WorkerError{Code: CodeInvalidAudio})
	o, _ := outcome(t, a)
	var workerErr *WorkerError
	if !errors.As(o.Err, &workerErr) || workerErr.Code != CodeInvalidAudio {
		t.Fatalf("%+v", o)
	}
	expectClosed(t, a)
	c := f.next(t)
	if c.id() != 200 {
		t.Fatal(c.id())
	}
	c.ok()
	if o, _ := outcome(t, b); o.Err != nil {
		t.Fatal(o.Err)
	}
}

func TestSchedulerRejectsBadWindows(t *testing.T) {
	s, _, _ := startScheduler(t)
	x := s.Open(1, 1)
	if err := x.Submit(Window{Index: 0}); !errors.Is(err, ErrInvalidRecognition) {
		t.Fatal(err)
	}
	if err := x.Submit(Window{Index: 0, Samples: make([]float32, MaxSampleCount+1)}); !errors.Is(err, ErrInvalidRecognition) {
		t.Fatal(err)
	}
	if err := x.Submit(Window{Index: 1, Samples: []float32{1}}); !errors.Is(err, ErrOutOfOrder) {
		t.Fatal(err)
	}
}

func TestSchedulerStopAnswersWaitingJobs(t *testing.T) {
	f := newFakeRecognizer()
	s := NewScheduler(SchedulerConfig{Recognizer: f})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.Run(ctx)
	}()
	a, b := s.Open(1, 1), s.Open(2, 2)
	submit(t, a, 1, 0)
	running := f.next(t)
	submit(t, b, 2, 0)
	cancel()
	running.fail(ErrWorkerUnavailable)
	<-done
	for _, x := range []*Session{a, b} {
		if o, _ := outcome(t, x); !errors.Is(o.Err, ErrWorkerUnavailable) {
			t.Fatalf("%+v", o)
		}
	}
	if err := s.Open(3, 3).Submit(window(3, 0)); !errors.Is(err, ErrWorkerUnavailable) {
		t.Fatal(err)
	}
}

// Multi-user fairness (T084, SC-002 logic rather than timing).

// trace records submissions and worker starts in the order they happen.
type trace struct {
	mu     sync.Mutex
	events []traceEvent
}

type traceEvent struct {
	start bool
	job   int // user*100 + index; rewrites are negative
}

func (tr *trace) add(start bool, job int) {
	tr.mu.Lock()
	defer tr.mu.Unlock()
	tr.events = append(tr.events, traceEvent{start, job})
}

// othersBefore counts, per other user, the windows that started after job was
// submitted and before it started.
func (tr *trace) othersBefore(t *testing.T, job int) map[int]int {
	t.Helper()
	tr.mu.Lock()
	defer tr.mu.Unlock()
	counts := map[int]int{}
	submitted := false
	for _, e := range tr.events {
		switch {
		case e.job == job && !e.start:
			submitted = true
		case e.job == job && e.start:
			return counts
		case submitted && e.start && e.job >= 0 && e.job/100 != job/100:
			counts[e.job/100]++
		}
	}
	t.Fatalf("job %d never started", job)
	return nil
}

// drain answers jobs in order, recording each start, until n have run.
func drain(t *testing.T, f *fakeRecognizer, tr *trace, n int, onStart func(job int)) {
	t.Helper()
	for i := 0; i < n; i++ {
		c := f.next(t)
		tr.add(true, c.id())
		if onStart != nil {
			onStart(c.id())
		}
		c.ok()
	}
}

// With N users releasing together, each tail window starts after at most one
// window from each other user, so at most N-1 in all. Every rotation of the
// submission order is tried, with the worker idle and with it still busy on
// an earlier window at release.
func TestFairnessTailsReleasingTogether(t *testing.T) {
	for _, users := range []int{2, 4} {
		for rotate := 0; rotate < users; rotate++ {
			for _, busy := range []bool{false, true} {
				t.Run(fmt.Sprintf("users=%d/rotate=%d/busy=%v", users, rotate, busy), func(t *testing.T) {
					s, f, _ := startScheduler(t)
					tr := &trace{}
					sessions := map[int64]*Session{}
					// Earlier windows are recognized while each user still
					// speaks; the last user's may still be running at release.
					var running *call
					for u := int64(1); u <= int64(users); u++ {
						sessions[u] = s.Open(u, u)
						submit(t, sessions[u], u, 0)
						c := f.next(t)
						tr.add(true, c.id())
						if busy && u == int64(users) {
							running = c
							break
						}
						c.ok()
						_, _ = outcome(t, sessions[u])
					}
					var tails []int
					for i := 0; i < users; i++ {
						u := int64((i+rotate)%users + 1)
						tr.add(false, int(id(u, 1)))
						submit(t, sessions[u], u, 1)
						tails = append(tails, int(id(u, 1)))
					}
					if running != nil {
						running.ok()
					}
					drainAll(t, s, f, tr)
					for _, tail := range tails {
						counts := tr.othersBefore(t, tail)
						total := 0
						for user, n := range counts {
							if n > 1 {
								t.Fatalf("tail %d waited behind %d windows of user %d", tail, n, user)
							}
							total += n
						}
						if total > users-1 {
							t.Fatalf("tail %d waited behind %d windows", tail, total)
						}
					}
				})
			}
		}
	}
}

// drainAll answers every remaining job in order, recording starts.
func drainAll(t *testing.T, s *Scheduler, f *fakeRecognizer, tr *trace) {
	t.Helper()
	for {
		select {
		case c := <-f.calls:
			tr.add(true, c.id())
			c.ok()
		case <-time.After(20 * time.Millisecond):
			if s.Waiting() == 0 && len(f.calls) == 0 {
				return
			}
		}
	}
}

// Rewrites that arrive while windows wait start only once no window waits,
// with windows from several users queued behind a running one.
func TestFairnessDictationAheadOfRewrites(t *testing.T) {
	s, f, _ := startScheduler(t)
	a, b := s.Open(1, 1), s.Open(2, 2)
	submit(t, a, 1, 0)
	running := f.next(t)
	submit(t, a, 1, 1)
	submit(t, b, 2, 0)
	submit(t, b, 2, 1)
	var started atomic.Int32
	var wg sync.WaitGroup
	for r := 0; r < 2; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if s.WaitForNoDictationWindows(context.Background()) == nil {
				started.Add(1)
			}
		}()
	}
	running.ok()
	for i := 0; i < 3; i++ {
		c := f.next(t)
		if i < 2 {
			// Windows still wait behind this one.
			time.Sleep(20 * time.Millisecond)
			if started.Load() != 0 {
				t.Fatalf("a rewrite started with %d windows waiting", s.Waiting())
			}
		}
		c.ok()
	}
	wg.Wait()
	if started.Load() != 2 {
		t.Fatal(started.Load())
	}
}

// A user who keeps their queue full, refilling it every time one of their
// windows starts, delays another user's window by at most one window.
func TestFairnessFullQueueDelaysOthersByOneWindow(t *testing.T) {
	s, f, _ := startScheduler(t)
	tr := &trace{}
	a, b := s.Open(1, 1), s.Open(2, 2)
	tr.add(false, int(id(1, 0)))
	submit(t, a, 1, 0)
	next := 1
	running := f.next(t)
	tr.add(true, running.id())
	for s.Waiting() < 2 {
		tr.add(false, int(id(1, next)))
		submit(t, a, 1, next)
		next++
	}
	tr.add(false, int(id(2, 0)))
	submit(t, b, 2, 0)
	running.ok()
	for {
		c := f.next(t)
		tr.add(true, c.id())
		if c.id() == int(id(2, 0)) {
			c.ok()
			break
		}
		// a refills its queue as soon as one of its windows starts.
		if next < MaxSessionWindows {
			tr.add(false, int(id(1, next)))
			submit(t, a, 1, next)
			next++
		}
		c.ok()
	}
	if n := tr.othersBefore(t, int(id(2, 0)))[1]; n > 1 {
		t.Fatalf("user 2 waited behind %d windows of user 1", n)
	}
	a.Cancel()
}

// Regression: a user whose session was cancelled with windows waiting, and who
// then starts a new session, rejoins the ring once, at the back.
func TestFairnessCancelledUserRejoinsAtBack(t *testing.T) {
	s, f, _ := startScheduler(t)
	a, b := s.Open(1, 1), s.Open(2, 2)
	submit(t, b, 2, 0)
	running := f.next(t)
	submit(t, a, 1, 0)
	submit(t, b, 2, 1)
	a.Cancel()
	a2 := s.Open(1, 1)
	submit(t, a2, 1, 0)
	submit(t, a2, 1, 1)
	running.ok()
	var order []int
	for i := 0; i < 3; i++ {
		c := f.next(t)
		order = append(order, c.id())
		c.ok()
	}
	if fmt.Sprint(order) != "[201 100 101]" {
		t.Fatal(order)
	}
}

// TrySubmit leaves a full user's session open and queues once a window of
// theirs has gone to the worker.
func TestSchedulerTrySubmitWaitsForRoom(t *testing.T) {
	s, f, _ := startScheduler(t)
	a := s.Open(1, 1)
	submit(t, a, 1, 0)
	running := f.next(t)
	submit(t, a, 1, 1)
	submit(t, a, 1, 2)
	if queued, err := a.TrySubmit(window(1, 3)); queued || err != nil {
		t.Fatal(queued, err)
	}
	if a.Progress() != ProgressRecognizing {
		t.Fatal(a.Progress())
	}
	running.ok()
	if o, _ := outcome(t, a); o.Err != nil || o.Index != 0 {
		t.Fatalf("%+v", o)
	}
	f.next(t).ok() // window 1 left the queue
	if queued, err := a.TrySubmit(window(1, 3)); !queued || err != nil {
		t.Fatal(queued, err)
	}
	for want := 1; want <= 3; want++ {
		if want > 1 {
			f.next(t).ok()
		}
		if o, _ := outcome(t, a); o.Err != nil || o.Index != want {
			t.Fatalf("want %d: %+v", want, o)
		}
	}
}

// live submits one live-preview window for user and returns its answer.
func live(s *Scheduler, ctx context.Context, user int64, tag int) chan answer {
	out := make(chan answer, 1)
	go func() {
		r, err := s.Live(ctx, user, 100+user, []float32{float32(tag), 0})
		out <- answer{result: r, err: err}
	}()
	return out
}

func waitLive(t *testing.T, s *Scheduler, n int) {
	t.Helper()
	eventually(t, "live windows waiting", func() bool { return s.LiveWaiting() == n })
}

// Dictation windows run before live-preview windows; inside each class
// users are served round robin (Feature 018 R3, R7).
func TestSchedulerDictationBeforeLive(t *testing.T) {
	s, f, _ := startScheduler(t)
	a := s.Open(1, 10)
	submit(t, a, 1, 0)
	first := f.next(t)
	l2 := live(s, context.Background(), 2, 200)
	waitLive(t, s, 1)
	l3 := live(s, context.Background(), 3, 300)
	waitLive(t, s, 2)
	d := s.Open(4, 40)
	submit(t, d, 4, 0)
	submit(t, a, 1, 1)
	first.ok()
	// Both dictation windows, round robin, then the live windows in order.
	for _, want := range []int{400, 101, 200, 300} {
		c := f.next(t)
		if c.id() != want {
			t.Fatalf("ran %d, want %d", c.id(), want)
		}
		c.ok()
	}
	for _, l := range []chan answer{l2, l3} {
		if a := <-l; a.err != nil || a.result.RecognitionMS != 3 {
			t.Fatalf("%+v", a)
		}
	}
}

// At most one live window per user waits; a second is busy. A running one
// does not count.
func TestSchedulerLiveOneWaitingPerUser(t *testing.T) {
	s, f, _ := startScheduler(t)
	running := live(s, context.Background(), 1, 1)
	c := f.next(t)
	waiting := live(s, context.Background(), 1, 2)
	waitLive(t, s, 1)
	if _, err := s.Live(context.Background(), 1, 101, []float32{3}); !errors.Is(err, ErrBusy) {
		t.Fatal(err)
	}
	// Another user is not affected.
	other := live(s, context.Background(), 2, 4)
	waitLive(t, s, 2)
	c.ok()
	for _, want := range []int{2, 4} {
		c := f.next(t)
		if c.id() != want {
			t.Fatalf("ran %d, want %d", c.id(), want)
		}
		c.ok()
	}
	for _, l := range []chan answer{running, waiting, other} {
		if a := <-l; a.err != nil {
			t.Fatal(a.err)
		}
	}
	if _, err := s.Live(context.Background(), 1, 101, nil); !errors.Is(err, ErrInvalidRecognition) {
		t.Fatal(err)
	}
}

// A live window whose caller gives up leaves the queue at once and never
// reaches the worker; live windows never hold back a rewrite.
func TestSchedulerLiveCancelAndRewriteGate(t *testing.T) {
	s, f, _ := startScheduler(t)
	a := s.Open(1, 10)
	submit(t, a, 1, 0)
	first := f.next(t)
	ctx, cancel := context.WithCancel(context.Background())
	l := live(s, ctx, 2, 200)
	waitLive(t, s, 1)
	if err := s.WaitForNoDictationWindows(context.Background()); err != nil {
		t.Fatal(err)
	}
	cancel()
	if got := <-l; !errors.Is(got.err, context.Canceled) {
		t.Fatal(got.err)
	}
	waitLive(t, s, 0)
	first.ok()
	f.none(t)
}

// Run returning answers waiting live windows with worker_unavailable.
func TestSchedulerLiveOnStop(t *testing.T) {
	f := newFakeRecognizer()
	s := NewScheduler(SchedulerConfig{Recognizer: f})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { defer close(done); s.Run(ctx) }()
	running := live(s, context.Background(), 1, 1)
	c := f.next(t)
	waiting := live(s, context.Background(), 2, 2)
	waitLive(t, s, 1)
	cancel()
	c.fail(ErrWorkerUnavailable)
	for _, l := range []chan answer{running, waiting} {
		if a := <-l; !errors.Is(a.err, ErrWorkerUnavailable) {
			t.Fatal(a.err)
		}
	}
	<-done
	if _, err := s.Live(context.Background(), 1, 1, []float32{1}); !errors.Is(err, ErrWorkerUnavailable) {
		t.Fatal(err)
	}
}
