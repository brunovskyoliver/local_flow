package speech

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// The test binary doubles as the fake worker: with SPEECH_FAKE_WORKER set it
// speaks the IPC contract on stdin/stdout instead of running tests. It is not
// flowd-speech, which is the point of FR-029.
func TestMain(m *testing.M) {
	if mode := os.Getenv("SPEECH_FAKE_WORKER"); mode != "" {
		os.Exit(fakeWorker(mode))
	}
	os.Exit(m.Run())
}

// Job behaviours, selected by the first sample of a recognize.
const (
	jobCrash      = -1 // exit 3 (non-zero exit)
	jobHang       = -2 // never answer
	jobMalformed  = -3 // write a malformed frame
	jobExit       = -4 // exit 0 without answering (EOF)
	jobError      = -5 // answer error failed
	jobGrandchild = -6 // start a grandchild in the same process group, then hang
	jobWrongID    = -7 // answer with another job's ID
)

func fakeWorker(mode string) int {
	send := func(h Header, payload []byte) {
		if err := WriteFrame(os.Stdout, h, payload); err != nil {
			os.Exit(5)
		}
	}
	model := &ModelIdentity{Engine: "Fake", ModelID: "fake-model", ModelRevision: "1", ManifestHash: "fake-hash", SDK: "none", Booster: "fake-booster", WorkerBuild: "fake-worker"}
	switch mode {
	case "sleep":
		time.Sleep(time.Hour)
		return 0
	case "crash-at-start":
		return 1
	case "unavailable":
		send(Header{Type: TypeUnavailable, Reason: "model_missing"}, nil)
		return 0
	case "unavailable-once":
		path := os.Getenv("SPEECH_FAKE_STATE")
		if _, err := os.Stat(path); err != nil {
			_ = os.WriteFile(path, nil, 0o600)
			send(Header{Type: TypeUnavailable, Reason: "model_missing"}, nil)
			return 0
		}
	case "result-first":
		ms := 1
		send(Header{Type: TypeResult, Job: 1, Window: json.RawMessage(`{}`), RecognitionMS: &ms}, nil)
		time.Sleep(time.Hour)
		return 0
	case "no-booster":
		model.Booster = ""
	case "meeting", "meeting-unavailable":
		return fakeMeetingWorker(mode)
	}
	send(Header{Type: TypeReady, Protocol: ProtocolVersion, Model: model}, nil)
	if mode == "ready-then-exit" {
		return 2
	}
	for {
		f, err := ReadFrame(os.Stdin)
		if err != nil {
			return 0
		}
		if f.Header.Type == TypeShutdown {
			fmt.Fprintln(os.Stderr, "state=shutdown")
			return 0
		}
		samples, _ := DecodeSamples(f.Payload)
		fmt.Fprintf(os.Stderr, "job=%d samples=%d\n", f.Header.Job, len(samples))
		send(Header{Type: TypeState, State: "active"}, nil)
		switch samples[0] {
		case jobCrash:
			return 3
		case jobHang:
			time.Sleep(time.Hour)
		case jobMalformed:
			_, _ = os.Stdout.Write([]byte{0, 0, 0, 3, 'x', 'y', 'z', 0, 0, 0, 0})
			time.Sleep(time.Hour)
		case jobExit:
			return 0
		case jobError:
			send(Header{Type: TypeError, Job: f.Header.Job, Code: CodeFailed}, nil)
			continue
		case jobGrandchild:
			child := exec.Command(os.Args[0])
			child.Env = append(os.Environ(), "SPEECH_FAKE_WORKER=sleep")
			if child.Start() != nil {
				return 6
			}
			fmt.Fprintf(os.Stderr, "grandchild=%d\n", child.Process.Pid)
			time.Sleep(time.Hour)
		case jobWrongID:
			ms := 1
			send(Header{Type: TypeResult, Job: f.Header.Job + 1, Window: json.RawMessage(`{}`), RecognitionMS: &ms}, nil)
			continue
		}
		ms := 7
		boosted := 0
		if f.Header.Boost != nil {
			boosted = len(f.Header.Boost.Terms)
		}
		window := fmt.Sprintf(`{"sample_count":%d,"boost_terms":%d,"first":%g}`, len(samples), boosted, samples[0])
		send(Header{Type: TypeResult, Job: f.Header.Job, Window: json.RawMessage(window), RecognitionMS: &ms}, nil)
	}
}

// fakeClock hands every timer to the test, which fires it explicitly.
type fakeClock struct{ timers chan *fakeTimer }

type fakeTimer struct {
	d       time.Duration
	c       chan time.Time
	stopped atomic.Bool
}

func newFakeClock() *fakeClock { return &fakeClock{timers: make(chan *fakeTimer, 256)} }

func (c *fakeClock) NewTimer(d time.Duration) Timer {
	t := &fakeTimer{d: d, c: make(chan time.Time, 1)}
	c.timers <- t
	return t
}
func (t *fakeTimer) C() <-chan time.Time { return t.c }
func (t *fakeTimer) Stop() bool          { return !t.stopped.Swap(true) }
func (t *fakeTimer) fire()               { t.c <- time.Now() }

// await returns the next live timer of duration d, skipping others.
func (c *fakeClock) await(t *testing.T, d time.Duration) *fakeTimer {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case tm := <-c.timers:
			if tm.d == d && !tm.stopped.Load() {
				return tm
			}
		case <-deadline:
			t.Fatalf("no %v timer", d)
		}
	}
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}
func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.String()
}

func eventually(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for " + what)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

type harness struct {
	s      *Supervisor
	clock  *fakeClock
	logs   *syncBuffer
	states chan State
	cancel context.CancelFunc
	done   chan struct{}
}

func startSupervisor(t *testing.T, mode string, env ...string) *harness {
	t.Helper()
	return startSupervisorWith(t, mode, nil, env...)
}

func startSupervisorWith(t *testing.T, mode string, configure func(*SupervisorConfig), env ...string) *harness {
	t.Helper()
	h := &harness{clock: newFakeClock(), logs: &syncBuffer{}, states: make(chan State, 256), done: make(chan struct{})}
	c := SupervisorConfig{
		Command:      []string{os.Args[0]},
		Env:          append(append(os.Environ(), "SPEECH_FAKE_WORKER="+mode), env...),
		Logger:       log.New(h.logs, "", 0),
		Clock:        h.clock,
		ReadyTimeout: -1,
		OnState:      func(s State) { h.states <- s },
	}
	if configure != nil {
		configure(&c)
	}
	h.s = NewSupervisor(c)
	ctx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel
	go func() {
		defer close(h.done)
		h.s.Run(ctx)
	}()
	t.Cleanup(h.stop)
	return h
}

func (h *harness) stop() {
	h.cancel()
	select {
	case <-h.done:
	case <-time.After(5 * time.Second):
		panic("supervisor did not stop")
	}
}

func (h *harness) await(t *testing.T, want State) {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case s := <-h.states:
			if s == want {
				return
			}
		case <-deadline:
			t.Fatalf("state %s never reached (now %s)", want, h.s.State())
		}
	}
}

func recognize(t *testing.T, s *Supervisor, samples ...float32) (WindowResult, error) {
	t.Helper()
	return s.Recognize(context.Background(), Recognition{Samples: samples})
}

func sampleCount(t *testing.T, r WindowResult) int {
	t.Helper()
	var w struct {
		SampleCount int `json:"sample_count"`
	}
	if err := json.Unmarshal(r.Window, &w); err != nil {
		t.Fatal(err)
	}
	return w.SampleCount
}

func TestSupervisorReadyAndRecognize(t *testing.T) {
	h := startSupervisor(t, "serve")
	h.await(t, StateReady)
	model, ok := h.s.Model()
	if !ok || model.Engine != "Fake" || model.ModelID != "fake-model" || model.ManifestHash != "fake-hash" || model.Booster != "fake-booster" || model.WorkerBuild != "fake-worker" {
		t.Fatalf("%+v %v", model, ok)
	}
	for i := 1; i <= 3; i++ {
		r, err := h.s.Recognize(context.Background(), Recognition{Samples: []float32{0.5, 0.25, float32(i)}, Boost: &Boost{Terms: []BoostTerm{{EntryID: "e", Canonical: "Secretterm"}}, Governed: []string{}}})
		if err != nil || sampleCount(t, r) != 3 || r.RecognitionMS != 7 || !strings.Contains(string(r.Window), `"boost_terms":1`) {
			t.Fatal(string(r.Window), err)
		}
	}
	eventually(t, "worker log lines", func() bool {
		return strings.Contains(h.logs.String(), "worker job=1 samples=3\n") && strings.Contains(h.logs.String(), "worker job=3 samples=3\n")
	})
	if strings.Contains(h.logs.String(), "Secretterm") {
		t.Fatal("term leaked into the log")
	}
}

func TestSupervisorReadyWithoutBooster(t *testing.T) {
	h := startSupervisor(t, "no-booster")
	h.await(t, StateReady)
	if model, ok := h.s.Model(); !ok || model.Booster != "" {
		t.Fatalf("%+v", model)
	}
}

func TestSupervisorRejectsBadInput(t *testing.T) {
	h := startSupervisor(t, "serve")
	h.await(t, StateReady)
	for _, samples := range [][]float32{nil, make([]float32, MaxSampleCount+1)} {
		if _, err := recognize(t, h.s, samples...); err == nil || errors.Is(err, ErrWorkerUnavailable) {
			t.Fatal(err)
		}
	}
	huge := &Boost{Governed: []string{strings.Repeat("a", MaxHeaderBytes)}}
	if _, err := h.s.Recognize(context.Background(), Recognition{Samples: []float32{1}, Boost: huge}); !errors.Is(err, ErrHeaderTooLarge) {
		t.Fatal(err)
	}
	// Nothing was sent, so the worker keeps serving.
	if r, err := recognize(t, h.s, 1); err != nil || sampleCount(t, r) != 1 {
		t.Fatal(err)
	}
}

func TestSupervisorWorkerErrorKeepsWorker(t *testing.T) {
	h := startSupervisor(t, "serve")
	h.await(t, StateReady)
	_, err := recognize(t, h.s, jobError)
	var workerErr *WorkerError
	if !errors.As(err, &workerErr) || workerErr.Code != CodeFailed {
		t.Fatal(err)
	}
	if r, err := recognize(t, h.s, 1, 2); err != nil || sampleCount(t, r) != 2 {
		t.Fatal(err)
	}
	if h.s.State() != StateReady {
		t.Fatal(h.s.State())
	}
}

func TestSupervisorReadyRequiredFirst(t *testing.T) {
	h := startSupervisor(t, "result-first")
	h.await(t, StateRestarting)
	h.clock.await(t, time.Second)
	if _, err := recognize(t, h.s, 1); !errors.Is(err, ErrWorkerUnavailable) {
		t.Fatal(err)
	}
	if _, ok := h.s.Model(); ok {
		t.Fatal("model reported without ready")
	}
}

func TestSupervisorUnavailableRetriesEvery60s(t *testing.T) {
	h := startSupervisor(t, "unavailable")
	for i := 0; i < 3; i++ {
		h.await(t, StateUnavailable)
		tm := h.clock.await(t, time.Minute)
		if _, err := recognize(t, h.s, 1); !errors.Is(err, ErrWorkerUnavailable) {
			t.Fatal(err)
		}
		tm.fire()
		h.await(t, StateStarting)
	}
	if !strings.Contains(h.logs.String(), "reason=model_missing") {
		t.Fatal(h.logs.String())
	}
}

func TestSupervisorUnavailableThenModelInstalled(t *testing.T) {
	h := startSupervisor(t, "unavailable-once", "SPEECH_FAKE_STATE="+filepath.Join(t.TempDir(), "started"))
	h.await(t, StateUnavailable)
	h.clock.await(t, time.Minute).fire()
	h.await(t, StateReady)
	if r, err := recognize(t, h.s, 1); err != nil || sampleCount(t, r) != 1 {
		t.Fatal(err)
	}
}

// Each failure kills the worker, answers the waiting job with
// worker_unavailable and restarts after 1 s; the supervisor then serves again.
func TestSupervisorFailuresRestart(t *testing.T) {
	for _, tc := range []struct {
		name string
		job  float32
	}{
		{"crash", jobCrash}, {"eof", jobExit}, {"malformed", jobMalformed}, {"deadline", jobHang}, {"wrong job id", jobWrongID},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := startSupervisor(t, "serve")
			h.await(t, StateReady)
			errs := make(chan error, 1)
			go func() {
				_, err := recognize(t, h.s, tc.job)
				errs <- err
			}()
			if tc.job == jobHang {
				h.clock.await(t, 30*time.Second).fire()
			}
			select {
			case err := <-errs:
				if !errors.Is(err, ErrWorkerUnavailable) {
					t.Fatal(err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("job not answered")
			}
			h.await(t, StateRestarting)
			h.clock.await(t, time.Second).fire()
			h.await(t, StateReady)
			if r, err := recognize(t, h.s, 1, 2); err != nil || sampleCount(t, r) != 2 {
				t.Fatal(err)
			}
		})
	}
}

func TestSupervisorIdleExitRestarts(t *testing.T) {
	h := startSupervisor(t, "ready-then-exit")
	h.await(t, StateReady)
	h.await(t, StateRestarting)
	h.clock.await(t, time.Second).fire()
	h.await(t, StateReady)
}

func TestSupervisorBackoffDoublesToCap(t *testing.T) {
	h := startSupervisor(t, "crash-at-start")
	for _, d := range []time.Duration{1, 2, 4, 8, 16, 32, 60, 60} {
		h.clock.await(t, d*time.Second).fire()
	}
	if _, err := recognize(t, h.s, 1); !errors.Is(err, ErrWorkerUnavailable) {
		t.Fatal(err)
	}
}

// A job that succeeds resets the backoff to 1 s.
func TestSupervisorBackoffResetsAfterJob(t *testing.T) {
	h := startSupervisor(t, "serve")
	h.await(t, StateReady)
	for i := 0; i < 3; i++ {
		if _, err := recognize(t, h.s, 1); err != nil {
			t.Fatal(err)
		}
		if _, err := recognize(t, h.s, jobCrash); !errors.Is(err, ErrWorkerUnavailable) {
			t.Fatal(err)
		}
		h.clock.await(t, time.Second).fire()
		h.await(t, StateReady)
	}
}

func TestSupervisorKillsProcessGroup(t *testing.T) {
	h := startSupervisor(t, "serve")
	h.await(t, StateReady)
	errs := make(chan error, 1)
	go func() {
		_, err := recognize(t, h.s, jobGrandchild)
		errs <- err
	}()
	pattern := regexp.MustCompile(`worker grandchild=(\d+)`)
	var pid int
	eventually(t, "grandchild pid", func() bool {
		m := pattern.FindStringSubmatch(h.logs.String())
		if m != nil {
			pid, _ = strconv.Atoi(m[1])
		}
		return m != nil
	})
	if syscall.Kill(pid, 0) != nil {
		t.Fatal("grandchild not running")
	}
	h.clock.await(t, 30*time.Second).fire()
	if err := <-errs; !errors.Is(err, ErrWorkerUnavailable) {
		t.Fatal(err)
	}
	eventually(t, "grandchild killed", func() bool { return syscall.Kill(pid, 0) != nil })
}

func TestSupervisorShutdownOnCancel(t *testing.T) {
	h := startSupervisor(t, "serve")
	h.await(t, StateReady)
	h.stop()
	if h.s.State() != StateStopped {
		t.Fatal(h.s.State())
	}
	eventually(t, "worker shutdown line", func() bool { return strings.Contains(h.logs.String(), "worker state=shutdown") })
	if _, err := recognize(t, h.s, 1); !errors.Is(err, ErrWorkerUnavailable) {
		t.Fatal(err)
	}
}

// The scheduler on the real supervisor: a job past its deadline kills the
// worker, every waiting window of every session gets worker_unavailable, and
// sessions opened after the restart are served.
func TestSchedulerOnSupervisorDeadline(t *testing.T) {
	h := startSupervisor(t, "serve")
	h.await(t, StateReady)
	s := NewScheduler(SchedulerConfig{Recognizer: h.s})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.Run(ctx)
	a, b := s.Open(1, 1), s.Open(2, 2)
	if err := a.Submit(Window{Index: 0, Samples: []float32{jobHang}}); err != nil {
		t.Fatal(err)
	}
	deadline := h.clock.await(t, 30*time.Second)
	for i := 0; i < 2; i++ {
		if err := b.Submit(Window{Index: i, Samples: []float32{1, 2}}); err != nil {
			t.Fatal(err)
		}
	}
	deadline.fire()
	for _, x := range []*Session{a, b} {
		if o := <-x.Results(); !errors.Is(o.Err, ErrWorkerUnavailable) || o.Index != 0 {
			t.Fatalf("%+v", o)
		}
	}
	h.clock.await(t, time.Second).fire()
	h.await(t, StateReady)
	c := s.Open(3, 3)
	if err := c.Submit(Window{Index: 0, Samples: []float32{1, 2, 3}}); err != nil {
		t.Fatal(err)
	}
	if o := <-c.Results(); o.Err != nil || sampleCount(t, o.Result) != 3 {
		t.Fatalf("%+v", o)
	}
}

// Meeting job behaviours, selected by the first s16le sample.
const (
	meetingHang         = 100 // never answer
	meetingNoModel      = 101 // answer error model_unavailable
	meetingInvalidAudio = 102 // answer error invalid_audio
)

// fakeMeetingWorker speaks the meeting worker contract. Its result echoes the
// kind, the sample count and the first sample scaled back to s16.
func fakeMeetingWorker(mode string) int {
	send := func(h Header) {
		if err := WriteFrame(os.Stdout, h, nil); err != nil {
			os.Exit(5)
		}
	}
	if mode == "meeting-unavailable" {
		send(Header{Type: TypeUnavailable, Reason: "model_missing", Missing: []string{"whisper-turbo"}})
		return 0
	}
	send(Header{Type: TypeReady, Protocol: ProtocolVersion, Models: testMeetingModels()})
	for {
		f, err := ReadFrame(os.Stdin)
		if err != nil {
			return 0
		}
		if f.Header.Type == TypeShutdown {
			return 0
		}
		samples, _ := DecodeSamples(f.Payload)
		fmt.Fprintf(os.Stderr, "job=%d kind=%s samples=%d\n", f.Header.Job, f.Header.Type, len(samples))
		send(Header{Type: TypeState, State: "loading"})
		switch int(samples[0] * 32768) {
		case meetingHang:
			time.Sleep(time.Hour)
		case meetingNoModel:
			send(Header{Type: TypeError, Job: f.Header.Job, Code: CodeModelUnavailable})
			continue
		case meetingInvalidAudio:
			send(Header{Type: TypeError, Job: f.Header.Job, Code: CodeInvalidAudio})
			continue
		}
		ms := 11
		result := fmt.Sprintf(`{"kind":%q,"samples":%d,"first":%g,"language":%q,"speakers":%d}`,
			f.Header.Type, len(samples), samples[0]*32768, f.Header.Language, deref(f.Header.NumSpeakers))
		send(Header{Type: TypeResult, Job: f.Header.Job, Kind: f.Header.Type, Result: json.RawMessage(result), ProcessingMS: &ms})
	}
}

func deref(p *int) int {
	if p == nil {
		return 0
	}
	return *p
}

func s16(values ...int16) []byte {
	out := make([]byte, 2*len(values))
	for i, v := range values {
		out[2*i], out[2*i+1] = byte(v), byte(uint16(v)>>8)
	}
	return out
}

func meetingSupervisor(t *testing.T, mode string, configure func(*SupervisorConfig)) *harness {
	t.Helper()
	return startSupervisorWith(t, mode, func(c *SupervisorConfig) {
		c.Meeting = true
		c.JobDeadline = MeetingJobDeadline
		if configure != nil {
			configure(c)
		}
	})
}

func TestMeetingSupervisorJobs(t *testing.T) {
	h := meetingSupervisor(t, "meeting", nil)
	h.await(t, StateReady)
	models, ok := h.s.MeetingModels()
	if !ok || models.Voice.Dimension != 256 || models.Transcription.ModelID != "whisper-turbo" {
		t.Fatalf("%+v %v", models, ok)
	}
	if _, ok := h.s.Model(); ok {
		t.Fatal("meeting worker reported a dictation model")
	}
	speakers := 2
	for _, tc := range []struct {
		job   MeetingJob
		model string
		want  string
	}{
		{MeetingJob{Kind: TypeTranscribe, Samples: s16(7, 1), Language: "auto", VocabularyTerms: []string{"Secretterm"}}, "whisper-turbo", `"first":7,"kind":"transcribe","language":"auto","samples":2`},
		{MeetingJob{Kind: TypeDiarize, Samples: s16(-9), NumSpeakers: &speakers}, "pyannote", `"first":-9,"kind":"diarize","language":"","samples":1,"speakers":2`},
		{MeetingJob{Kind: TypeEmbed, Samples: make([]byte, 2*48000)}, "wespeaker", `"first":0,"kind":"embed","language":"","samples":48000`},
	} {
		r, err := h.s.Meeting(context.Background(), tc.job)
		if err != nil || !strings.Contains(string(r.Result), tc.want) || r.ProcessingMS != 11 || r.Model.ModelID != tc.model {
			t.Fatalf("%s: %s %+v %v", tc.job.Kind, r.Result, r.Model, err)
		}
	}
	for _, bad := range []MeetingJob{
		{Kind: TypeEmbed, Samples: make([]byte, 2*47999)},
		{Kind: TypeTranscribe, Samples: nil},
		{Kind: TypeRecognize, Samples: s16(1)},
		{Kind: TypeTranscribe, Samples: []byte{1, 2, 3}},
	} {
		if _, err := h.s.Meeting(context.Background(), bad); !errors.Is(err, ErrInvalidRecognition) {
			t.Fatalf("%s %d bytes: %v", bad.Kind, len(bad.Samples), err)
		}
	}
	_, err := h.s.Meeting(context.Background(), MeetingJob{Kind: TypeTranscribe, Samples: s16(meetingNoModel)})
	var workerErr *WorkerError
	if !errors.As(err, &workerErr) || workerErr.Code != CodeModelUnavailable {
		t.Fatal(err)
	}
	// A dictation recognize is not a meeting job.
	if _, err := recognize(t, h.s, 1); !errors.Is(err, ErrInvalidRecognition) {
		t.Fatal(err)
	}
	eventually(t, "worker log line", func() bool { return strings.Contains(h.logs.String(), "worker job=1 kind=transcribe samples=2") })
	if strings.Contains(h.logs.String(), "Secretterm") {
		t.Fatal("term leaked into the log")
	}
}

// The meeting worker's deadline is 300 s (the dictation worker keeps 30 s):
// on it the worker is killed, the job answers worker_unavailable and the
// worker restarts after the Feature 014 backoff.
func TestMeetingSupervisorDeadline(t *testing.T) {
	h := meetingSupervisor(t, "meeting", nil)
	h.await(t, StateReady)
	errs := make(chan error, 1)
	go func() {
		_, err := h.s.Meeting(context.Background(), MeetingJob{Kind: TypeDiarize, Samples: s16(meetingHang, 0, 0)})
		errs <- err
	}()
	h.clock.await(t, 300*time.Second).fire()
	if err := <-errs; !errors.Is(err, ErrWorkerUnavailable) {
		t.Fatal(err)
	}
	h.await(t, StateRestarting)
	if _, ok := h.s.MeetingModels(); ok {
		t.Fatal("models reported while restarting")
	}
	h.clock.await(t, time.Second).fire()
	h.await(t, StateReady)
	if r, err := h.s.Meeting(context.Background(), MeetingJob{Kind: TypeEmbed, Samples: make([]byte, 2*48000)}); err != nil || r.ProcessingMS != 11 {
		t.Fatal(err)
	}
}

// unavailable at start-up: no models, so no meeting job kinds are offered.
func TestMeetingSupervisorUnavailable(t *testing.T) {
	h := meetingSupervisor(t, "meeting-unavailable", nil)
	h.await(t, StateUnavailable)
	if _, ok := h.s.MeetingModels(); ok {
		t.Fatal("models while unavailable")
	}
	if _, err := h.s.Meeting(context.Background(), MeetingJob{Kind: TypeTranscribe, Samples: s16(1)}); !errors.Is(err, ErrWorkerUnavailable) {
		t.Fatal(err)
	}
	eventually(t, "missing count", func() bool { return strings.Contains(h.logs.String(), "reason=model_missing missing=1") })
}

// Each supervisor accepts only its own worker's ready.
func TestSupervisorRefusesTheOtherWorkersReady(t *testing.T) {
	for _, tc := range []struct {
		mode    string
		meeting bool
	}{{"meeting", false}, {"serve", true}} {
		h := startSupervisorWith(t, tc.mode, func(c *SupervisorConfig) { c.Meeting = tc.meeting })
		h.await(t, StateRestarting)
		if !strings.Contains(h.logs.String(), "worker_failure=wrong_ready") {
			t.Fatal(h.logs.String())
		}
		h.stop()
	}
}

// While the gate is closed (interactive work in flight) no job is sent to
// the worker; a job waiting for it can still be abandoned.
func TestSupervisorGate(t *testing.T) {
	var mu sync.Mutex
	gate := make(chan struct{})
	h := meetingSupervisor(t, "meeting", func(c *SupervisorConfig) {
		c.Gate = func() <-chan struct{} {
			mu.Lock()
			defer mu.Unlock()
			return gate
		}
	})
	h.await(t, StateReady)
	ctx, cancel := context.WithCancel(context.Background())
	errs := make(chan error, 1)
	go func() {
		_, err := h.s.Meeting(ctx, MeetingJob{Kind: TypeTranscribe, Samples: s16(1)})
		errs <- err
	}()
	time.Sleep(50 * time.Millisecond)
	if strings.Contains(h.logs.String(), "worker job=") {
		t.Fatal("job sent through a closed gate")
	}
	cancel()
	if err := <-errs; !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() {
		_, err := h.s.Meeting(context.Background(), MeetingJob{Kind: TypeTranscribe, Samples: s16(2)})
		result <- err
	}()
	time.Sleep(20 * time.Millisecond)
	mu.Lock()
	close(gate)
	mu.Unlock()
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	if strings.Count(h.logs.String(), "worker job=") != 1 {
		t.Fatal("abandoned job reached the worker")
	}
}
