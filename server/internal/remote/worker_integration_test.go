package remote

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"log"
	"math"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"localflow/server/internal/analysis"
	"localflow/server/internal/rewrite"
	"localflow/server/internal/speech"
)

// TestRealWorkerWindowsDecode runs the real flowd-speech worker under the
// supervisor and checks that its answers pass the dictation operation's strict
// window decoding. Opt-in, because it needs the built worker and a verified
// model: set LOCALFLOW_SPEECH_WORKER (the executable), LOCALFLOW_SPEECH_MODELS
// (a Models directory without symlinks in its path) and LOCALFLOW_SPEECH_AUDIO
// (16 kHz mono Float32 little-endian samples, at least one second).
func TestRealWorkerWindowsDecode(t *testing.T) {
	worker, models, audio := os.Getenv("LOCALFLOW_SPEECH_WORKER"),
		os.Getenv("LOCALFLOW_SPEECH_MODELS"), os.Getenv("LOCALFLOW_SPEECH_AUDIO")
	if worker == "" || models == "" || audio == "" {
		t.Skip("set LOCALFLOW_SPEECH_WORKER, LOCALFLOW_SPEECH_MODELS and LOCALFLOW_SPEECH_AUDIO")
	}
	raw, err := os.ReadFile(audio)
	if err != nil {
		t.Fatal(err)
	}
	samples := make([]float32, min(len(raw)/4, WindowSamples))
	for i := range samples {
		samples[i] = math.Float32frombits(binary.LittleEndian.Uint32(raw[i*4:]))
	}
	supervisor := speech.NewSupervisor(speech.SupervisorConfig{
		Command: []string{worker, "serve", "--models", models},
		Logger:  log.New(os.Stderr, "supervisor ", 0),
	})
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	go supervisor.Run(ctx)
	for supervisor.State() != speech.StateReady {
		if ctx.Err() != nil {
			t.Fatalf("worker never became ready: %s", supervisor.State())
		}
		time.Sleep(50 * time.Millisecond)
	}
	model, ok := supervisor.Model()
	if !ok || model.Engine != "FluidAudio" || model.ManifestHash == "" {
		t.Fatalf("model identity %+v", model)
	}
	boost := &speech.Boost{Terms: []speech.BoostTerm{{EntryID: "z", Canonical: "Zabbix"}},
		Governed: []string{"zabbix"}}
	for _, job := range []*speech.Boost{nil, boost} {
		result, err := supervisor.Recognize(ctx, speech.Recognition{Samples: samples, Boost: job})
		if err != nil {
			t.Fatalf("recognize: %v", err)
		}
		var w workerWindow
		if err := strictDecode(result.Window, &w); err != nil {
			t.Fatalf("worker window refused: %v", err)
		}
		if w.SampleCount != len(samples) || w.Text == "" || w.Evidence == nil {
			t.Fatalf("window %d samples, %d text bytes, evidence %v", w.SampleCount, len(w.Text), w.Evidence != nil)
		}
		message := WindowResult{Op: 1, Index: 0, SampleStart: 0, SampleCount: w.SampleCount, Text: w.Text,
			Tokens: w.Tokens, Evidence: w.Evidence, BoostHints: w.BoostHints, RecognitionMS: int64(result.RecognitionMS)}
		if _, err := EncodeMessage(message); err != nil {
			t.Fatalf("window_result refused: %v", err)
		}
		t.Logf("window: %d samples, %d ms, %d tokens, %d hints", w.SampleCount, result.RecognitionMS, len(w.Tokens), len(w.BoostHints))
	}
}

// Feature 018 T085 (FR-027, SC-007 logic only): the dictation, rewrite,
// analysis and meeting operations over one real MeetingQueue, speech
// scheduler and rewrite-first gate, with fake workers on one shared device
// and the harness's manual clock. No timing here is a measurement.

// meetingJobTime is how long a meeting job holds the device, in clock time.
const meetingJobTime = 2 * time.Minute

// deviceRecognizer is the dictation worker: each window waits for the
// shared device and reports how long it waited, in clock time.
type deviceRecognizer struct {
	device  *sync.Mutex
	clock   *manualClock
	entered chan struct{}
	waited  chan time.Duration
}

func (r *deviceRecognizer) Recognize(_ context.Context, job speech.Recognition) (speech.WindowResult, error) {
	start := r.clock.Now()
	r.entered <- struct{}{}
	r.device.Lock()
	defer r.device.Unlock()
	r.waited <- r.clock.Now().Sub(start)
	return speech.WindowResult{Window: workerWindowJSON(len(job.Samples), "dictated", nil), RecognitionMS: 5}, nil
}

// gatedMeetingWorker is the meeting worker as the supervisor drives it: one
// process, so one job at a time; each job is written only once the gate
// (MeetingQueue.InteractiveIdle) is open and then holds the device until
// the test answers it.
type gatedMeetingWorker struct {
	*fakeMeetingWorker
	gate   func() <-chan struct{}
	serial sync.Mutex
	device *sync.Mutex
}

func (w *gatedMeetingWorker) Meeting(ctx context.Context, j speech.MeetingJob) (speech.MeetingResult, error) {
	w.serial.Lock()
	defer w.serial.Unlock()
	select {
	case <-w.gate():
	case <-ctx.Done():
		return speech.MeetingResult{}, ctx.Err()
	}
	w.device.Lock()
	defer w.device.Unlock()
	return w.fakeMeetingWorker.Meeting(ctx, j)
}

// within receives from c or fails the test after 5 s.
func within[T any](t *testing.T, c <-chan T) T {
	t.Helper()
	select {
	case v := <-c:
		return v
	case <-time.After(5 * time.Second):
		t.Fatal("timed out")
		var zero T
		return zero
	}
}

type sharingHarness struct {
	*harness
	queue      *speech.MeetingQueue
	worker     *gatedMeetingWorker
	recognizer *deviceRecognizer
	gate       *analysis.Gate
	analysis   *echoBackend // the summaries backend; holds each call
}

func newSharingHarness(t *testing.T) *sharingHarness {
	t.Helper()
	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	queue := speech.NewMeetingQueue(nil)
	device := &sync.Mutex{}
	worker := &gatedMeetingWorker{fakeMeetingWorker: &fakeMeetingWorker{calls: make(chan *meetingCall, 8), state: speech.StateReady},
		gate: queue.InteractiveIdle, device: device}
	recognizer := &deviceRecognizer{device: device, clock: h.clock, entered: make(chan struct{}, 8), waited: make(chan time.Duration, 8)}
	scheduler := speech.NewScheduler(speech.SchedulerConfig{Recognizer: recognizer})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go scheduler.Run(ctx)
	gate := analysis.NewGate(0, true)
	summaries := &echoBackend{hold: make(chan struct{}), started: make(chan struct{}, 8)}
	operations[PurposeSession]["dictation_start"] = NewDictation(DictationConfig{Scheduler: SchedulerSessions(scheduler),
		Models: &fakeModels{model: testModel(), ok: true}, Clock: h.clock, Interactive: queue.BeginInteractive}).Start
	operations[PurposeSession]["rewrite"] = NewRewriter(RewriteConfig{Runner: rewrite.NewHandler(rewrite.HandlerConfig{
		Backend: &echoBackend{}, Gate: gate}), Windows: scheduler, Interactive: queue.BeginInteractive}).Start
	operations[PurposeSession]["analysis"] = NewAnalyzer(AnalysisConfig{Runner: analysis.NewHandler(analysis.HandlerConfig{
		Backend: summaries, Gate: gate, Limits: analysis.DefaultLimits()}), Clock: h.clock}).Start
	operations[PurposeSession]["meeting_job"] = NewMeeting(MeetingConfig{Worker: worker, Queue: queue, Clock: h.clock}).Start
	return &sharingHarness{h, queue, worker, recognizer, gate, summaries}
}

func (h *sharingHarness) sendMeetingJob(c *testClient, op int64) {
	c.send(MeetingJob{Op: op, Kind: "transcribe", SampleCount: 4, Format: SampleFormat})
	c.sendS16(0, 4, 4)
}

// User A's meeting job holds the device and user C's has started too. User
// B's dictation window waits for A's job only: C's job and A's next one do
// not reach the worker until B's dictation ends.
func TestDictationWaitsAtMostOneMeetingJob(t *testing.T) {
	h := newSharingHarness(t)
	_, _, tokenA := h.approved("a", 1)
	_, _, tokenB := h.approved("b", 2)
	_, _, tokenC := h.approved("c", 3)

	a1, _ := h.hello(PurposeSession, tokenA)
	h.sendMeetingJob(a1, 1)
	expectProgress(t, a1.recv(), 1, "running")
	jobA := h.worker.next(t)
	c1, _ := h.hello(PurposeSession, tokenC)
	h.sendMeetingJob(c1, 1)
	expectProgress(t, c1.recv(), 1, "running") // started; the worker is busy with A's
	a2, _ := h.hello(PurposeSession, tokenA)
	h.sendMeetingJob(a2, 2)
	expectProgress(t, a2.recv(), 2, "queued") // A's own running slot is taken

	b, _ := h.hello(PurposeSession, tokenB)
	b.send(startMessage(1))
	if _, ok := b.recv().(DictationAccepted); !ok {
		t.Fatal("dictation refused")
	}
	b.sendSamples(0, WindowSamples, MaxAudioSamples)
	within(t, h.recognizer.entered)
	h.clock.Advance(meetingJobTime)
	jobA.reply <- meetingAnswer{result: transcribeResult}
	if m, ok := a1.recv().(MeetingResult); !ok || m.Op != 1 {
		t.Fatalf("%#v", m)
	}
	if waited := within(t, h.recognizer.waited); waited > meetingJobTime {
		t.Fatalf("dictation waited %s, more than one meeting job", waited)
	}
	for {
		if m := b.recv(); m.MessageType() == "window_result" {
			break
		} else if m.MessageType() != "progress" {
			t.Fatalf("%#v", m)
		}
	}
	// B's dictation is still open: no other meeting job reaches the worker.
	h.worker.none(t)
	if h.queue.Waiting() != 1 {
		t.Fatalf("%d waiting, want A's second job", h.queue.Waiting())
	}
	b.send(DictationEnd{Op: 1, TotalSamples: WindowSamples})
	for b.recv().MessageType() != "dictation_complete" {
	}
	// Then C's job runs, and A's next one after it.
	h.worker.next(t).reply <- meetingAnswer{result: transcribeResult}
	if m, ok := c1.recv().(MeetingResult); !ok || m.Op != 1 {
		t.Fatalf("%#v", m)
	}
	expectProgress(t, a2.recv(), 2, "running")
	h.worker.next(t).reply <- meetingAnswer{result: transcribeResult}
	if m, ok := a2.recv().(MeetingResult); !ok || m.Op != 2 {
		t.Fatalf("%#v", m)
	}
}

// A rewrite from either user preempts a running analysis: the rewrite
// completes and the analysis ends with preempted.
func TestRewritePreemptsAnalysis(t *testing.T) {
	h := newSharingHarness(t)
	_, _, tokenA := h.approved("a", 1)
	_, _, tokenB := h.approved("b", 2)
	for i, tc := range []struct{ analyst, rewriter string }{{tokenB, tokenA}, {tokenA, tokenA}} {
		op := int64(i + 1)
		summaries, _ := h.hello(PurposeSession, tc.analyst)
		summaries.sendAnalysis(op, analysisRequest(t, 2, nil), MaxAnalysisPartBytes)
		within(t, h.analysis.started)
		writer, _ := h.hello(PurposeSession, tc.rewriter)
		writer.send(Rewrite{Op: op, Request: json.RawMessage(rewriteBody("Rewrite me."))})
		for {
			e, ok := writer.recv().(RewriteEvent)
			if !ok || strings.Contains(string(e.Event), `"event":"error"`) {
				t.Fatalf("%d: rewrite %#v", i, e)
			}
			if strings.Contains(string(e.Event), `"event":"result"`) {
				break
			}
		}
		events, _ := summaries.analysisEvents(op)
		if last := string(events[len(events)-1]); !strings.Contains(last, `"code":"preempted"`) {
			t.Fatalf("%d: analysis ended with %s", i, last)
		}
	}
	if h.gate.Preemptions() != 2 {
		t.Fatalf("%d preemptions", h.gate.Preemptions())
	}
}

// A user with one meeting job running and MaxMeetingWaitingPerUser more is
// answered busy; other users' meeting jobs and dictation are not.
func TestSaturatedMeetingQueueAnswersBusy(t *testing.T) {
	h := newSharingHarness(t)
	_, _, tokenA := h.approved("a", 1)
	_, _, tokenA2 := h.approved("a", 4) // A's second device, for more channels
	_, _, tokenB := h.approved("b", 2)
	var channels []*testClient
	for op := int64(1); op <= 1+speech.MaxMeetingWaitingPerUser; op++ {
		token := tokenA
		if op > 2 {
			token = tokenA2
		}
		c, _ := h.hello(PurposeSession, token)
		h.sendMeetingJob(c, op)
		c.recv() // running for the first, queued for the rest
		channels = append(channels, c)
	}
	running := h.worker.next(t)
	over, _ := h.hello(PurposeSession, tokenA2)
	over.send(MeetingJob{Op: 9, Kind: "transcribe", SampleCount: 4, Format: SampleFormat})
	expectError(t, over.recv(), 9, CodeBusy)
	// B's meeting job is admitted.
	b, _ := h.hello(PurposeSession, tokenB)
	h.sendMeetingJob(b, 1)
	expectProgress(t, b.recv(), 1, "running")
	// Once A's running job ends and the next one starts, A may queue again.
	running.reply <- meetingAnswer{result: transcribeResult}
	if m, ok := channels[0].recv().(MeetingResult); !ok || m.Op != 1 {
		t.Fatalf("%#v", m)
	}
	expectProgress(t, channels[1].recv(), 2, "running")
	channels[0].send(MeetingJob{Op: 4, Kind: "transcribe", SampleCount: 4, Format: SampleFormat})
	channels[0].sendS16(0, 4, 4)
	expectProgress(t, channels[0].recv(), 4, "queued")
	// B's dictation starts while the queue is full.
	bd, _ := h.hello(PurposeSession, tokenB)
	bd.send(startMessage(2))
	if _, ok := bd.recv().(DictationAccepted); !ok {
		t.Fatal("dictation refused")
	}
}
