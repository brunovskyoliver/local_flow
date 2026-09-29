package remote

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"localflow/server/internal/speech"
)

// fakeModels is the supervisor's Model() for tests.
type fakeModels struct {
	mu    sync.Mutex
	model speech.ModelIdentity
	ok    bool
}

func (f *fakeModels) Model() (speech.ModelIdentity, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.model, f.ok
}

func testModel() speech.ModelIdentity {
	return speech.ModelIdentity{Engine: "FluidAudio", ModelID: "parakeet-tdt-0.6b-v3", ModelRevision: "rev-1",
		ManifestHash: "sha256-0011", SDK: "0.15.7", Booster: "ctc110m-v1", WorkerBuild: "test-1"}
}

// fakeScheduler records every session it opens.
type fakeScheduler struct {
	mu       sync.Mutex
	sessions []*fakeSession
}

func (f *fakeScheduler) Open(user, channel int64) SpeechSession {
	s := &fakeSession{user: user, channel: channel, results: make(chan speech.Outcome, 32), room: -1}
	f.mu.Lock()
	f.sessions = append(f.sessions, s)
	f.mu.Unlock()
	return s
}

func (f *fakeScheduler) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.sessions)
}

func (f *fakeScheduler) session(t *testing.T, i int) *fakeSession {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		f.mu.Lock()
		if len(f.sessions) > i {
			s := f.sessions[i]
			f.mu.Unlock()
			return s
		}
		f.mu.Unlock()
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("session %d never opened", i)
	return nil
}

// fakeSession is a scheduler session the test drives by hand.
type fakeSession struct {
	user, channel int64
	results       chan speech.Outcome

	mu        sync.Mutex
	windows   []speech.Window
	submitErr error
	progress  speech.Progress
	cancelled bool
	room      int // see setRoom
	answered  int // windows delivered
}

func (s *fakeSession) TrySubmit(w speech.Window) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancelled {
		return false, speech.ErrCancelled
	}
	if s.submitErr != nil {
		return false, s.submitErr
	}
	if s.room >= 0 && len(s.windows)-s.answered >= s.room {
		return false, nil
	}
	s.windows = append(s.windows, w)
	return true, nil
}

// setRoom limits how many submitted windows may be unanswered at once, like
// the scheduler's per-user queue; -1 (the default) is unlimited.
func (s *fakeSession) setRoom(n int) {
	s.mu.Lock()
	s.room = n
	s.mu.Unlock()
}

func (s *fakeSession) Results() <-chan speech.Outcome { return s.results }

func (s *fakeSession) Cancel() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.cancelled {
		s.cancelled = true
		close(s.results)
	}
}

func (s *fakeSession) Progress() speech.Progress {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.progress
}

func (s *fakeSession) setProgress(p speech.Progress) {
	s.mu.Lock()
	s.progress = p
	s.mu.Unlock()
}

func (s *fakeSession) isCancelled() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cancelled
}

// waitWindows waits until n windows were submitted and returns them.
func (s *fakeSession) waitWindows(t *testing.T, n int) []speech.Window {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		if len(s.windows) >= n {
			out := append([]speech.Window(nil), s.windows...)
			s.mu.Unlock()
			return out
		}
		s.mu.Unlock()
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("only %d windows submitted, want %d", len(s.windows), n)
	return nil
}

// deliver answers window w with a valid worker window object.
func (s *fakeSession) deliver(w speech.Window, text string) {
	s.mu.Lock()
	s.answered++
	s.mu.Unlock()
	s.results <- speech.Outcome{Index: w.Index, SampleStart: w.SampleStart, SampleCount: len(w.Samples),
		Result: speech.WindowResult{Window: workerWindowJSON(len(w.Samples), text, nil), RecognitionMS: 42}}
}

func workerWindowJSON(samples int, text string, hints []BoostHint) json.RawMessage {
	if hints == nil {
		hints = []BoostHint{}
	}
	data, _ := json.Marshal(map[string]any{
		"sample_count": samples, "text": text,
		"tokens":      []Token{{Text: text, Start: 0.12, End: 0.4}},
		"boost_hints": hints,
		"evidence": map[string]any{"text": text, "samples": samples, "padded_samples": samples, "timings_available": true,
			"tokens": []map[string]any{{"text": text, "start": map[string]any{"value": 0.12}, "end": map[string]any{"value": 0.4}}}},
	})
	return data
}

// dictationHarness is a listener whose session channel runs the real
// dictation operation over a fake scheduler.
type dictationHarness struct {
	*harness
	dictation *Dictation
	scheduler *fakeScheduler
	models    *fakeModels
}

func newDictationHarness(t *testing.T, configure func(*DictationConfig)) *dictationHarness {
	t.Helper()
	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	scheduler := &fakeScheduler{}
	models := &fakeModels{model: testModel(), ok: true}
	cfg := DictationConfig{Scheduler: scheduler, Models: models, Clock: h.clock}
	if configure != nil {
		configure(&cfg)
	}
	d := NewDictation(cfg)
	operations[PurposeSession]["dictation_start"] = d.Start
	return &dictationHarness{h, d, scheduler, models}
}

func startMessage(op int64) DictationStart {
	return DictationStart{Op: op, Format: AudioFormat, SampleRate: SampleRate}
}

// sendSamples sends samples first…first+n-1 (each sample's value is its
// index) in frames of at most frame samples.
func (c *testClient) sendSamples(first, n, frame int) {
	c.t.Helper()
	for sent := 0; sent < n; {
		size := min(frame, n-sent)
		payload := make([]byte, 4*size)
		for i := range size {
			binary.LittleEndian.PutUint32(payload[4*i:], math.Float32bits(float32(first+sent+i)))
		}
		c.sendFrame(Frame{KindAudio, payload})
		sent += size
	}
}

// recvSkippingProgress returns the next message that is not progress.
func (c *testClient) recvSkippingProgress() Message {
	c.t.Helper()
	for {
		m := c.recv()
		if m.MessageType() != "progress" {
			return m
		}
	}
}

func (h *dictationHarness) op(t *testing.T) *dictationOp {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if ops := h.dictation.liveOps(); len(ops) == 1 {
			return ops[0]
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("no single live dictation")
	return nil
}

func (h *dictationHarness) waitNoLive(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if len(h.dictation.liveOps()) == 0 && h.dictation.sessions() == 0 {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("dictation still holds %d ops, %d sessions", len(h.dictation.liveOps()), h.dictation.sessions())
}

// dictation_accepted carries window_samples 239,360 and the worker's model
// identity; booster is absent when the worker has none.
func TestDictationAccepted(t *testing.T) {
	h := newDictationHarness(t, nil)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(startMessage(1))
	accepted, ok := c.recv().(DictationAccepted)
	want := ModelIdentity{Engine: "FluidAudio", ModelID: "parakeet-tdt-0.6b-v3", ModelRevision: "rev-1",
		ManifestHash: "sha256-0011", SDK: "0.15.7", Booster: "ctc110m-v1", WorkerBuild: "test-1"}
	if !ok || accepted.Op != 1 || accepted.WindowSamples != 239360 || accepted.Model != want {
		t.Fatalf("%#v", accepted)
	}
	c.send(DictationCancel{Op: 1})
	if m, ok := c.recv().(Cancelled); !ok || m.Op != 1 {
		t.Fatalf("%#v", m)
	}

	model := testModel()
	model.Booster = ""
	h.models.mu.Lock()
	h.models.model = model
	h.models.mu.Unlock()
	c.send(startMessage(2))
	if accepted, ok := c.recv().(DictationAccepted); !ok || accepted.Model.Booster != "" {
		t.Fatalf("%#v", accepted)
	}
}

// With no ready worker, dictation_start is answered worker_unavailable and the
// channel stays open.
func TestDictationWorkerUnavailable(t *testing.T) {
	h := newDictationHarness(t, nil)
	h.models.mu.Lock()
	h.models.ok = false
	h.models.mu.Unlock()
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(startMessage(1))
	expectError(t, c.recv(), 1, CodeWorkerUnavailable)
	h.models.mu.Lock()
	h.models.ok = true
	h.models.mu.Unlock()
	c.send(startMessage(2))
	if _, ok := c.recv().(DictationAccepted); !ok {
		t.Fatal("channel did not stay usable")
	}
}

// Windows are cut contiguously from sample 0; window 0 is queued before
// dictation_end; the remainder becomes the tail job; results go out in index
// order, then dictation_complete with the window count. Boost terms go to
// every job of that session.
func TestDictationWindowsAndTail(t *testing.T) {
	h := newDictationHarness(t, nil)
	user, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	start := startMessage(1)
	start.Boost = &Boost{Terms: []BoostTerm{{EntryID: "e1", Canonical: "Zabbix"}}, Governed: []string{"zabbix"}}
	c.send(start)
	c.recv()
	session := h.scheduler.session(t, 0)
	if session.user != user.ID {
		t.Fatalf("session opened for user %d", session.user)
	}
	const tail = 1000
	total := 2*WindowSamples + tail
	c.sendSamples(0, WindowSamples+5, MaxAudioSamples)
	if got := session.waitWindows(t, 1); len(got) != 1 {
		t.Fatal(len(got))
	}
	c.sendSamples(WindowSamples+5, total-(WindowSamples+5), 7000)
	windows := session.waitWindows(t, 2)
	if len(windows) != 2 {
		t.Fatalf("tail queued before dictation_end: %d", len(windows))
	}
	c.send(DictationEnd{Op: 1, TotalSamples: int64(total)})
	windows = session.waitWindows(t, 3)
	for i, w := range windows {
		size := WindowSamples
		if i == 2 {
			size = tail
		}
		if w.Index != i || w.SampleStart != i*WindowSamples || len(w.Samples) != size {
			t.Fatalf("window %d: index %d start %d samples %d", i, w.Index, w.SampleStart, len(w.Samples))
		}
		for j, v := range w.Samples {
			if v != float32(i*WindowSamples+j) {
				t.Fatalf("window %d sample %d = %v", i, j, v)
			}
		}
		if w.Boost == nil || len(w.Boost.Terms) != 1 || w.Boost.Terms[0] != (speech.BoostTerm{EntryID: "e1", Canonical: "Zabbix"}) ||
			fmt.Sprint(w.Boost.Governed) != "[zabbix]" {
			t.Fatalf("window %d boost %#v", i, w.Boost)
		}
	}
	for i, w := range windows {
		session.deliver(w, fmt.Sprintf("text %d", i))
	}
	for i := range 3 {
		result, ok := c.recvSkippingProgress().(WindowResult)
		if !ok || result.Op != 1 || result.Index != i || result.SampleStart != i*WindowSamples ||
			result.SampleCount != len(windows[i].Samples) || result.Text != fmt.Sprintf("text %d", i) ||
			result.RecognitionMS != 42 || result.Evidence == nil || len(result.Tokens) != 1 {
			t.Fatalf("result %d: %#v", i, result)
		}
	}
	if m, ok := c.recvSkippingProgress().(DictationComplete); !ok || m.Op != 1 || m.Windows != 3 {
		t.Fatalf("%#v", m)
	}
	h.waitNoLive(t)
	// The channel can start the next operation at once.
	c.send(startMessage(2))
	if _, ok := c.recv().(DictationAccepted); !ok {
		t.Fatal("next dictation refused")
	}
}

// A session of exactly one window has no tail; an empty session completes
// with zero windows; results delivered before dictation_end complete at end.
func TestDictationExactWindowAndEmpty(t *testing.T) {
	h := newDictationHarness(t, nil)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(startMessage(1))
	c.recv()
	session := h.scheduler.session(t, 0)
	c.sendSamples(0, WindowSamples, MaxAudioSamples)
	w := session.waitWindows(t, 1)[0]
	session.deliver(w, "one")
	if r, ok := c.recvSkippingProgress().(WindowResult); !ok || r.Index != 0 {
		t.Fatalf("%#v", r)
	}
	c.send(DictationEnd{Op: 1, TotalSamples: WindowSamples})
	if m, ok := c.recvSkippingProgress().(DictationComplete); !ok || m.Windows != 1 {
		t.Fatalf("%#v", m)
	}
	if got := session.waitWindows(t, 1); len(got) != 1 {
		t.Fatal("tail submitted for an exact window")
	}
	c.send(startMessage(2))
	c.recv()
	c.send(DictationEnd{Op: 2, TotalSamples: 0})
	if m, ok := c.recv().(DictationComplete); !ok || m.Op != 2 || m.Windows != 0 {
		t.Fatalf("%#v", m)
	}
}

// progress goes out at most every 500 ms, and only while a window is queued
// or running.
func TestDictationProgress(t *testing.T) {
	h := newDictationHarness(t, nil)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(startMessage(1))
	c.recv()
	session := h.scheduler.session(t, 0)
	h.clock.waitTimer(t, ProgressInterval)
	// Idle: no progress.
	h.clock.Advance(ProgressInterval)
	c.sendSamples(0, WindowSamples, MaxAudioSamples)
	w := session.waitWindows(t, 1)[0]
	session.setProgress(speech.ProgressQueued)
	h.clock.waitTimer(t, ProgressInterval)
	h.clock.Advance(ProgressInterval - time.Millisecond)
	h.clock.Advance(time.Millisecond)
	if m, ok := c.recv().(Progress); !ok || m.Op != 1 || m.State != "queued" {
		t.Fatalf("%#v", m)
	}
	session.setProgress(speech.ProgressRecognizing)
	h.clock.waitTimer(t, ProgressInterval)
	h.clock.Advance(ProgressInterval / 2)
	h.clock.Advance(ProgressInterval / 2)
	if m, ok := c.recv().(Progress); !ok || m.State != "recognizing" {
		t.Fatalf("%#v", m)
	}
	session.setProgress(speech.ProgressIdle)
	h.clock.waitTimer(t, ProgressInterval)
	h.clock.Advance(ProgressInterval)
	// Nothing was sent while idle: the next message is the result.
	session.deliver(w, "x")
	if m, ok := c.recv().(WindowResult); !ok {
		t.Fatalf("%#v", m)
	}
}

// total_samples mismatch, audio before dictation_start or after a refused
// start, audio after dictation_end and unexpected control messages are
// invalid_message.
func TestDictationInvalidMessages(t *testing.T) {
	h := newDictationHarness(t, nil)
	_, _, token := h.approved("a", 1)

	c, _ := h.hello(PurposeSession, token)
	c.send(startMessage(1))
	c.recv()
	c.sendSamples(0, 100, 100)
	c.send(DictationEnd{Op: 1, TotalSamples: 99})
	expectError(t, c.recv(), 1, CodeInvalidMessage)
	h.waitNoLive(t)
	c.ws.CloseNow()

	c, _ = h.hello(PurposeSession, token)
	c.send(startMessage(1))
	c.recv()
	c.sendSamples(0, 100, 100)
	c.send(DictationEnd{Op: 1, TotalSamples: 100})
	c.sendSamples(100, 10, 10)
	m := c.recv()
	if _, ok := m.(DictationComplete); ok {
		m = c.recv()
	}
	if e, ok := m.(ErrorMessage); ok {
		// Audio after end is refused whether or not the op completed first.
		if e.Code != CodeInvalidMessage {
			t.Fatalf("%#v", e)
		}
	} else {
		t.Fatalf("%#v", m)
	}
	c.ws.CloseNow()

	c, _ = h.hello(PurposeSession, token)
	c.sendSamples(0, 10, 10)
	expectError(t, c.recv(), 0, CodeInvalidMessage)
	c.ws.CloseNow()

	h.dictation.debugBusy.Store(true)
	c, _ = h.hello(PurposeSession, token)
	c.send(startMessage(1))
	expectError(t, c.recv(), 1, CodeBusy)
	c.sendSamples(0, 10, 10)
	expectError(t, c.recv(), 0, CodeInvalidMessage)
	c.ws.CloseNow()
	h.dictation.debugBusy.Store(false)

	c, _ = h.hello(PurposeSession, token)
	c.send(startMessage(1))
	c.recv()
	c.send(DictationStart{Op: 1, Format: AudioFormat, SampleRate: SampleRate})
	expectError(t, c.recv(), 1, CodeInvalidMessage)
	h.waitNoLive(t)
	c.ws.CloseNow()
}

// A frame over 16,000 samples or a session over 2,880,000 + 16,000 samples
// is limit_exceeded.
func TestDictationLimits(t *testing.T) {
	h := newDictationHarness(t, nil)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(startMessage(1))
	c.recv()
	sealed, _ := c.channel.sealPlaintext(Frame{KindAudio, make([]byte, 4*(MaxAudioSamples+1))}.plaintext())
	_ = c.ws.Write(context.Background(), websocket.MessageBinary, sealed)
	expectError(t, c.recv(), 1, CodeLimitExceeded)
	c.ws.CloseNow()
	h.waitNoLive(t)

	c, _ = h.hello(PurposeSession, token)
	c.send(startMessage(1))
	c.recv()
	session := h.scheduler.session(t, 1)
	c.sendSamples(0, MaxSessionSamples, MaxAudioSamples)
	c.sendSamples(MaxSessionSamples, 1, 1)
	expectError(t, c.recvSkippingProgress(), 1, CodeLimitExceeded)
	if !session.isCancelled() {
		t.Fatal("session not cancelled")
	}
	h.waitNoLive(t)

	// The operation checks the frame bound itself too.
	op := &dictationOp{}
	if err := op.Audio(context.Background(), make([]byte, 4*(MaxAudioSamples+1))); CodeOf(err) != CodeLimitExceeded {
		t.Fatal(err)
	}
}

// 8 dictation sessions total and 1 per user; a third channel of one device
// is refused at the hello.
func TestDictationBounds(t *testing.T) {
	h := newDictationHarness(t, nil)
	var clients []*testClient
	for i := range MaxDictationSessions {
		_, _, token := h.approved(fmt.Sprintf("user-%d", i), byte(i+1))
		c, _ := h.hello(PurposeSession, token)
		c.send(startMessage(1))
		if _, ok := c.recv().(DictationAccepted); !ok {
			t.Fatalf("session %d refused", i)
		}
		clients = append(clients, c)
	}
	_, _, token := h.approved("user-9", 99)
	c9, _ := h.hello(PurposeSession, token)
	c9.send(startMessage(1))
	expectError(t, c9.recv(), 1, CodeBusy)

	// Freeing one session admits the next.
	clients[0].send(DictationCancel{Op: 1})
	clients[0].recv()
	c9.send(startMessage(2))
	if _, ok := c9.recv().(DictationAccepted); !ok {
		t.Fatal("not admitted after a session ended")
	}

	// One per user: the same user on a second channel is busy.
	second, _ := h.hello(PurposeSession, token)
	second.send(startMessage(1))
	expectError(t, second.recv(), 1, CodeBusy)
	// Two channels per device: a third hello is busy.
	_, hello := h.hello(PurposeSession, token)
	expectError(t, hello, 0, CodeBusy)
}

// token_expired when the channel's access token has expired by the server
// clock at the operation start; the channel stays open.
func TestDictationTokenExpired(t *testing.T) {
	h := newDictationHarness(t, nil)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(startMessage(1))
	c.recv()
	c.send(DictationCancel{Op: 1})
	c.recv()
	h.clock.mu.Lock()
	h.clock.now = h.clock.now.Add(15 * time.Minute)
	h.clock.mu.Unlock()
	c.send(startMessage(2))
	expectError(t, c.recv(), 2, CodeTokenExpired)
	if h.scheduler.count() != 1 {
		t.Fatal("expired token opened a session")
	}
}

// dictation_cancel drops queued work, discards a running result and answers
// cancelled.
func TestDictationCancel(t *testing.T) {
	h := newDictationHarness(t, nil)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(startMessage(1))
	c.recv()
	session := h.scheduler.session(t, 0)
	c.sendSamples(0, WindowSamples+10, MaxAudioSamples)
	w := session.waitWindows(t, 1)[0]
	op := h.op(t)
	c.send(DictationCancel{Op: 1})
	if m, ok := c.recvSkippingProgress().(Cancelled); !ok || m.Op != 1 {
		t.Fatalf("%#v", m)
	}
	if !session.isCancelled() {
		t.Fatal("session not cancelled")
	}
	func() {
		defer func() { _ = recover() }() // results is closed after cancel
		session.deliver(w, "late")
	}()
	h.waitNoLive(t)
	if op.bufferCap() != 0 {
		t.Fatal("buffer kept after cancel")
	}
	c.send(startMessage(2))
	if m, ok := c.recv().(DictationAccepted); !ok {
		t.Fatalf("late result relayed or channel broken: %#v", m)
	}
}

// The session buffer never exceeds one window plus one frame, and is freed
// on end, cancel, error and channel close.
func TestDictationBufferBoundAndRelease(t *testing.T) {
	h := newDictationHarness(t, nil)
	_, _, token := h.approved("a", 1)
	for _, ending := range []string{"end", "cancel", "error", "close"} {
		c, _ := h.hello(PurposeSession, token)
		c.send(startMessage(1))
		c.recv()
		op := h.op(t)
		sent := 0
		for sent < 2*WindowSamples+5000 {
			c.sendSamples(sent, MaxAudioSamples, MaxAudioSamples)
			sent += MaxAudioSamples
			deadline := time.Now().Add(5 * time.Second)
			for op.received() != sent && time.Now().Before(deadline) {
				time.Sleep(100 * time.Microsecond)
			}
			if n, capacity := op.bufferLen(), op.bufferCap(); n >= WindowSamples || capacity > WindowSamples+MaxAudioSamples {
				t.Fatalf("%s: buffer %d samples, capacity %d", ending, n, capacity)
			}
		}
		switch ending {
		case "end":
			c.send(DictationEnd{Op: 1, TotalSamples: int64(sent)})
			session := h.scheduler.session(t, len(h.scheduler.sessions)-1)
			windows := session.waitWindows(t, 3)
			if op.bufferCap() != 0 {
				t.Fatal("end: buffer kept after the tail was queued")
			}
			for _, w := range windows {
				session.deliver(w, "x")
			}
			if m, ok := c.recvSkippingProgress().(WindowResult); !ok {
				t.Fatalf("%#v", m)
			}
		case "cancel":
			c.send(DictationCancel{Op: 1})
		case "error":
			c.send(DictationEnd{Op: 1, TotalSamples: 1})
		case "close":
			c.ws.CloseNow()
		}
		h.waitNoLive(t)
		if op.bufferCap() != 0 {
			t.Fatalf("%s: buffer not freed", ending)
		}
		c.ws.CloseNow()
	}
}

// --debug-busy answers every dictation_start with busy.
func TestDictationDebugBusy(t *testing.T) {
	h := newDictationHarness(t, func(c *DictationConfig) { c.DebugBusy = true })
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	for op := int64(1); op <= 3; op++ {
		c.send(startMessage(op))
		expectError(t, c.recv(), op, CodeBusy)
	}
	if h.scheduler.count() != 0 {
		t.Fatal("debug busy opened a session")
	}
}

// Scheduler and worker failures end the dictation with the matching code; a
// worker window that does not match its job is never relayed.
func TestDictationFailures(t *testing.T) {
	good := func(w speech.Window) speech.Outcome {
		return speech.Outcome{Index: w.Index, SampleStart: w.SampleStart, SampleCount: len(w.Samples),
			Result: speech.WindowResult{Window: workerWindowJSON(len(w.Samples), "ok", nil), RecognitionMS: 1}}
	}
	withWindow := func(raw string) func(speech.Window) speech.Outcome {
		return func(w speech.Window) speech.Outcome {
			o := good(w)
			o.Result.Window = json.RawMessage(raw)
			return o
		}
	}
	for name, tc := range map[string]struct {
		outcome func(speech.Window) speech.Outcome
		code    ErrorCode
	}{
		"busy": {func(w speech.Window) speech.Outcome { return speech.Outcome{Index: w.Index, Err: speech.ErrBusy} }, CodeBusy},
		"worker unavailable": {func(w speech.Window) speech.Outcome {
			return speech.Outcome{Index: w.Index, Err: speech.ErrWorkerUnavailable}
		}, CodeWorkerUnavailable},
		"model unavailable": {func(w speech.Window) speech.Outcome {
			return speech.Outcome{Err: &speech.WorkerError{Code: speech.CodeModelUnavailable}}
		}, CodeWorkerUnavailable},
		"invalid audio": {func(w speech.Window) speech.Outcome {
			return speech.Outcome{Err: &speech.WorkerError{Code: speech.CodeInvalidAudio}}
		}, CodeInvalidMessage},
		"worker failed": {func(w speech.Window) speech.Outcome {
			return speech.Outcome{Err: &speech.WorkerError{Code: speech.CodeFailed}}
		}, CodeInternal},
		"header too large":    {func(w speech.Window) speech.Outcome { return speech.Outcome{Err: speech.ErrHeaderTooLarge} }, CodeInvalidMessage},
		"sample count":        {withWindow(`{"sample_count":5,"text":"x","tokens":[],"boost_hints":[]}`), CodeWorkerUnavailable},
		"missing field":       {withWindow(`{"sample_count":239360,"text":"x","boost_hints":[]}`), CodeWorkerUnavailable},
		"unknown field":       {withWindow(`{"sample_count":239360,"text":"x","tokens":[],"boost_hints":[],"extra":1}`), CodeWorkerUnavailable},
		"null tokens":         {withWindow(`{"sample_count":239360,"text":"x","tokens":null,"boost_hints":[]}`), CodeWorkerUnavailable},
		"negative timing":     {withWindow(`{"sample_count":239360,"text":"x","tokens":[{"text":"x","start":-1,"end":0}],"boost_hints":[]}`), CodeWorkerUnavailable},
		"foreign boost hint":  {withWindow(`{"sample_count":239360,"text":"x","tokens":[],"boost_hints":[{"source":"a","canonical":"Other","entry_id":"e9"}]}`), CodeWorkerUnavailable},
		"not an object":       {withWindow(`[1]`), CodeWorkerUnavailable},
		"wrong index":         {func(w speech.Window) speech.Outcome { o := good(w); o.Index = 1; return o }, CodeWorkerUnavailable},
		"wrong sample start":  {func(w speech.Window) speech.Outcome { o := good(w); o.SampleStart = 7; return o }, CodeWorkerUnavailable},
		"wrong outcome count": {func(w speech.Window) speech.Outcome { o := good(w); o.SampleCount = 9; return o }, CodeWorkerUnavailable},
	} {
		t.Run(name, func(t *testing.T) {
			h := newDictationHarness(t, nil)
			_, _, token := h.approved("a", 1)
			c, _ := h.hello(PurposeSession, token)
			c.send(startMessage(1))
			c.recv()
			session := h.scheduler.session(t, 0)
			c.sendSamples(0, WindowSamples, MaxAudioSamples)
			w := session.waitWindows(t, 1)[0]
			session.results <- tc.outcome(w)
			expectError(t, c.recvSkippingProgress(), 1, tc.code)
			h.waitNoLive(t)
			if !session.isCancelled() {
				t.Fatal("session not cancelled")
			}
			// The channel stays open for another operation.
			c.send(startMessage(2))
			if m, ok := c.recv().(DictationAccepted); !ok {
				t.Fatalf("%#v", m)
			}
		})
	}
}

// A boost hint naming one of the session's own terms is relayed.
func TestDictationOwnBoostHintRelayed(t *testing.T) {
	h := newDictationHarness(t, nil)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	start := startMessage(1)
	start.Boost = &Boost{Terms: []BoostTerm{{EntryID: "e1", Canonical: "Zabbix"}}, Governed: []string{}}
	c.send(start)
	c.recv()
	session := h.scheduler.session(t, 0)
	c.sendSamples(0, 100, 100)
	c.send(DictationEnd{Op: 1, TotalSamples: 100})
	w := session.waitWindows(t, 1)[0]
	session.results <- speech.Outcome{Index: 0, SampleStart: 0, SampleCount: 100, Result: speech.WindowResult{
		Window: workerWindowJSON(100, "check Zabbix", []BoostHint{{Source: "zabix", Canonical: "Zabbix", EntryID: "e1"}}), RecognitionMS: 3}}
	r, ok := c.recvSkippingProgress().(WindowResult)
	if !ok || len(r.BoostHints) != 1 || r.BoostHints[0].EntryID != "e1" || len(w.Samples) != 100 {
		t.Fatalf("%#v", r)
	}
}

// Submit refusing with busy (the user's queue is full) ends the dictation
// with busy.
func TestDictationSubmitBusy(t *testing.T) {
	h := newDictationHarness(t, nil)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(startMessage(1))
	c.recv()
	session := h.scheduler.session(t, 0)
	session.mu.Lock()
	session.submitErr = speech.ErrBusy
	session.mu.Unlock()
	c.sendSamples(0, WindowSamples, MaxAudioSamples)
	expectError(t, c.recvSkippingProgress(), 1, CodeBusy)
	h.waitNoLive(t)
}

// recordingRecognizer is a fake worker for the real scheduler: it records
// each job and answers with a window naming the job's own terms.
type recordingRecognizer struct {
	mu   sync.Mutex
	jobs []speech.Recognition
	gate chan struct{} // when set, each job waits for a value
}

func (r *recordingRecognizer) Recognize(ctx context.Context, job speech.Recognition) (speech.WindowResult, error) {
	if r.gate != nil {
		select {
		case <-r.gate:
		case <-ctx.Done():
			return speech.WindowResult{}, ctx.Err()
		}
	}
	r.mu.Lock()
	r.jobs = append(r.jobs, job)
	r.mu.Unlock()
	var hints []BoostHint
	text := fmt.Sprintf("first=%v", job.Samples[0])
	if job.Boost != nil {
		for _, term := range job.Boost.Terms {
			hints = append(hints, BoostHint{Source: strings.ToLower(term.Canonical), Canonical: term.Canonical, EntryID: term.EntryID})
			text += " " + term.Canonical
		}
	}
	return speech.WindowResult{Window: workerWindowJSON(len(job.Samples), text, hints), RecognitionMS: 5}, nil
}

func (r *recordingRecognizer) recorded() []speech.Recognition {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]speech.Recognition(nil), r.jobs...)
}

// The operation works end to end over the real speech.Scheduler.
func TestDictationWithRealScheduler(t *testing.T) {
	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	recognizer := &recordingRecognizer{}
	scheduler := speech.NewScheduler(speech.SchedulerConfig{Recognizer: recognizer})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go scheduler.Run(ctx)
	d := NewDictation(DictationConfig{Scheduler: SchedulerSessions(scheduler), Models: &fakeModels{model: testModel(), ok: true}, Clock: h.clock})
	operations[PurposeSession]["dictation_start"] = d.Start
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	start := startMessage(1)
	start.Boost = &Boost{Terms: []BoostTerm{{EntryID: "e1", Canonical: "Zabbix"}}, Governed: []string{"zabix"}}
	c.send(start)
	c.recv()
	total := WindowSamples + 300
	c.sendSamples(0, total, MaxAudioSamples)
	c.send(DictationEnd{Op: 1, TotalSamples: int64(total)})
	for i := range 2 {
		r, ok := c.recvSkippingProgress().(WindowResult)
		if !ok || r.Index != i || r.Text != fmt.Sprintf("first=%d Zabbix", i*WindowSamples) {
			t.Fatalf("%#v", r)
		}
	}
	if m, ok := c.recvSkippingProgress().(DictationComplete); !ok || m.Windows != 2 {
		t.Fatalf("%#v", m)
	}
	if jobs := recognizer.recorded(); len(jobs) != 2 || len(jobs[1].Samples) != 300 {
		t.Fatalf("%d jobs", len(jobs))
	}
}

// A whole recording uploaded faster than the worker runs (a queued retry or a
// reconnect resending from sample 0) waits for the user's queue instead of
// ending with busy.
func TestDictationBurstUploadWaitsForTheScheduler(t *testing.T) {
	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	recognizer := &recordingRecognizer{gate: make(chan struct{})}
	scheduler := speech.NewScheduler(speech.SchedulerConfig{Recognizer: recognizer})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go scheduler.Run(ctx)
	d := NewDictation(DictationConfig{Scheduler: SchedulerSessions(scheduler), Models: &fakeModels{model: testModel(), ok: true}, Clock: h.clock})
	operations[PurposeSession]["dictation_start"] = d.Start
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(startMessage(1))
	c.recv()
	// About 90 s: six windows, while the worker holds the first.
	total := 5*WindowSamples + 1_000
	c.sendSamples(0, total, MaxAudioSamples)
	c.send(DictationEnd{Op: 1, TotalSamples: int64(total)})
	go func() {
		for range 6 {
			select {
			case recognizer.gate <- struct{}{}:
			case <-ctx.Done():
				return
			}
		}
	}()
	for i := range 6 {
		r, ok := c.recvSkippingProgress().(WindowResult)
		if !ok || r.Index != i || r.SampleStart != i*WindowSamples {
			t.Fatalf("window %d: %#v", i, r)
		}
	}
	if m, ok := c.recvSkippingProgress().(DictationComplete); !ok || m.Windows != 6 {
		t.Fatalf("%#v", m)
	}
	if jobs := recognizer.recorded(); len(jobs) != 6 || len(jobs[5].Samples) != 1_000 {
		t.Fatalf("%d jobs", len(jobs))
	}
}

// Windows held for room are submitted as results free places, and the
// operation completes only once every held window has been answered.
func TestDictationHeldWindowsFollowResults(t *testing.T) {
	h := newDictationHarness(t, nil)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(startMessage(1))
	c.recv()
	session := h.scheduler.session(t, 0)
	session.setRoom(1)
	total := 3 * WindowSamples
	c.sendSamples(0, total, MaxAudioSamples)
	c.send(DictationEnd{Op: 1, TotalSamples: int64(total)})
	for i := range 3 {
		windows := session.waitWindows(t, i+1)
		if len(windows) != i+1 {
			t.Fatalf("window %d: %d submitted with room for one", i, len(windows))
		}
		session.deliver(windows[i], fmt.Sprintf("w%d", i))
		if r, ok := c.recvSkippingProgress().(WindowResult); !ok || r.Index != i {
			t.Fatalf("%#v", r)
		}
	}
	if m, ok := c.recvSkippingProgress().(DictationComplete); !ok || m.Windows != 3 {
		t.Fatalf("%#v", m)
	}
	h.waitNoLive(t)
}
