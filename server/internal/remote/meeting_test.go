package remote

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"localflow/server/internal/speech"
)

// fakeMeetingWorker hands each job to the test, which answers it.
type fakeMeetingWorker struct {
	calls chan *meetingCall
	mu    sync.Mutex
	state speech.State
}

type meetingCall struct {
	ctx   context.Context
	job   speech.MeetingJob
	reply chan meetingAnswer
}

type meetingAnswer struct {
	result string
	err    error
}

func testMeetingModels() speech.MeetingModels {
	model := func(engine, id string) *speech.MeetingModel {
		return &speech.MeetingModel{Engine: engine, ModelID: id, ModelRevision: "rev-1", ManifestHash: "sha256-" + id}
	}
	voice := model("FluidAudio", "wespeaker")
	voice.Dimension = 256
	return speech.MeetingModels{Transcription: model("whisper.cpp", "whisper-turbo"), Diarization: model("FluidAudio", "pyannote"), Voice: voice}
}

func (f *fakeMeetingWorker) setState(s speech.State) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.state = s
}

func (f *fakeMeetingWorker) State() speech.State {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.state
}

func (f *fakeMeetingWorker) MeetingModels() (speech.MeetingModels, bool) {
	if f.State() != speech.StateReady {
		return speech.MeetingModels{}, false
	}
	return testMeetingModels(), true
}

func (f *fakeMeetingWorker) Meeting(ctx context.Context, j speech.MeetingJob) (speech.MeetingResult, error) {
	c := &meetingCall{ctx: ctx, job: j, reply: make(chan meetingAnswer, 1)}
	f.calls <- c
	select {
	case a := <-c.reply:
		if a.err != nil {
			return speech.MeetingResult{}, a.err
		}
		return speech.MeetingResult{Result: json.RawMessage(a.result), ProcessingMS: 42, Model: testMeetingModels().For(j.Kind)}, nil
	case <-ctx.Done():
		return speech.MeetingResult{}, ctx.Err()
	}
}

func (f *fakeMeetingWorker) next(t *testing.T) *meetingCall {
	t.Helper()
	select {
	case c := <-f.calls:
		return c
	case <-time.After(5 * time.Second):
		t.Fatal("no meeting job reached the worker")
		return nil
	}
}

func (f *fakeMeetingWorker) none(t *testing.T) {
	t.Helper()
	select {
	case c := <-f.calls:
		t.Fatalf("unexpected %s job", c.job.Kind)
	case <-time.After(20 * time.Millisecond):
	}
}

type meetingHarness struct {
	*harness
	meeting *Meeting
	worker  *fakeMeetingWorker
	queue   *speech.MeetingQueue
}

func newMeetingHarness(t *testing.T) *meetingHarness {
	t.Helper()
	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	worker := &fakeMeetingWorker{calls: make(chan *meetingCall, 8), state: speech.StateReady}
	queue := speech.NewMeetingQueue(nil)
	m := NewMeeting(MeetingConfig{Worker: worker, Queue: queue, Clock: h.clock, Logger: h.listener.cfg.Logger})
	operations[PurposeSession]["meeting_job"] = m.Start
	return &meetingHarness{h, m, worker, queue}
}

const (
	transcribeResult = `{"text":"Secret words","tokens":[{"text":"Secret","start":0,"end":0.5}],"timings_available":true,"language":"en","retry_depth":0,"pipeline":"w120"}`
	diarizeResult    = `{"turns":[{"cluster":0,"start":0,"end":1.5}],"centroids":[{"cluster":0,"vector":[0.123456]}]}`
	embedResult      = `{"vector":[0.654321],"speech_seconds":3}`
)

func expectProgress(t *testing.T, m Message, op int64, state string) MeetingProgress {
	t.Helper()
	p, ok := m.(MeetingProgress)
	if !ok || p.Op != op || p.State != state {
		t.Fatalf("got %#v, want meeting_progress %s", m, state)
	}
	return p
}

// Each kind collects its samples, runs once its queue slot starts and
// answers meeting_result with the worker's result, processing time and the
// model of its kind; the samples are then deleted.
func TestMeetingJobKinds(t *testing.T) {
	h := newMeetingHarness(t)
	_, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)
	speakers := 2
	for i, tc := range []struct {
		job    MeetingJob
		result string
		model  string
	}{
		{MeetingJob{Kind: "transcribe", SampleCount: 3, Language: "auto", VocabularyTerms: []string{"Secretterm"}, Pipeline: "w120"}, transcribeResult, "whisper-turbo"},
		{MeetingJob{Kind: "diarize", SampleCount: 40000, NumSpeakers: &speakers}, diarizeResult, "pyannote"},
		{MeetingJob{Kind: "embed", SampleCount: 48000}, embedResult, "wespeaker"},
	} {
		op := int64(i + 1)
		tc.job.Op, tc.job.Format = op, SampleFormat
		c.send(tc.job)
		c.sendS16(-1, tc.job.SampleCount, MaxSampleFrameSamples)
		expectProgress(t, c.recv(), op, "running")
		call := h.worker.next(t)
		j := call.job
		if j.Kind != tc.job.Kind || len(j.Samples) != 2*tc.job.SampleCount || j.Samples[0] != 0xff || j.Samples[1] != 0xff ||
			j.Language != tc.job.Language || j.Pipeline != tc.job.Pipeline || len(j.VocabularyTerms) != len(tc.job.VocabularyTerms) ||
			(tc.job.NumSpeakers != nil && *j.NumSpeakers != speakers) {
			t.Fatalf("%s: %+v", tc.job.Kind, j.Kind)
		}
		call.reply <- meetingAnswer{result: tc.result}
		m, ok := c.recv().(MeetingResult)
		if !ok || m.Op != op || m.Kind != tc.job.Kind || string(m.Result) != tc.result || m.ProcessingMS != 42 || m.Model.ModelID != tc.model {
			t.Fatalf("%#v", m)
		}
		h.waitBuffered(t, h.meeting.buffered.Load)
	}
	if h.queue.Running() != 0 || h.queue.Waiting() != 0 {
		t.Fatal("queue slot held")
	}
	logs := h.logs.String()
	if !strings.Contains(logs, "kind=transcribe") || !strings.Contains(logs, "queue_depth=") {
		t.Fatal(logs)
	}
	for _, leaked := range []string{"Secret", "0.123456", "0.654321", "w120"} {
		if strings.Contains(logs, leaked) {
			t.Fatalf("%q in the log", leaked)
		}
	}
}

// While interactive work is in flight the job waits: meeting_progress
// queued with its position, then running once the work ends.
func TestMeetingJobQueued(t *testing.T) {
	h := newMeetingHarness(t)
	_, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)
	end := h.queue.BeginInteractive()
	c.send(MeetingJob{Op: 1, Kind: "embed", SampleCount: 48000, Format: SampleFormat})
	c.sendS16(0, 48000, MaxSampleFrameSamples)
	if p := expectProgress(t, c.recv(), 1, "queued"); p.Position == nil || *p.Position != 0 {
		t.Fatalf("%#v", p)
	}
	h.worker.none(t)
	end()
	expectProgress(t, c.recv(), 1, "running")
	h.worker.next(t).reply <- meetingAnswer{result: embedResult}
	if m, ok := c.recv().(MeetingResult); !ok || m.Op != 1 {
		t.Fatalf("%#v", m)
	}
}

// meeting_cancel stops a job while collecting, waiting or running: the
// client gets cancelled, the queue place and the samples are freed.
func TestMeetingJobCancel(t *testing.T) {
	h := newMeetingHarness(t)
	_, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)

	c.send(MeetingJob{Op: 1, Kind: "transcribe", SampleCount: 10, Format: SampleFormat})
	c.sendS16(0, 4, 4)
	c.send(MeetingCancel{Op: 1})
	if m, ok := c.recv().(Cancelled); !ok || m.Op != 1 {
		t.Fatalf("%#v", m)
	}
	h.waitBuffered(t, h.meeting.buffered.Load)

	end := h.queue.BeginInteractive()
	c.send(MeetingJob{Op: 2, Kind: "transcribe", SampleCount: 4, Format: SampleFormat})
	c.sendS16(0, 4, 4)
	expectProgress(t, c.recv(), 2, "queued")
	c.send(MeetingCancel{Op: 2})
	if m, ok := c.recv().(Cancelled); !ok || m.Op != 2 {
		t.Fatalf("%#v", m)
	}
	h.waitBuffered(t, h.meeting.buffered.Load)
	if h.queue.Waiting() != 0 {
		t.Fatal(h.queue.Waiting())
	}
	end()
	h.worker.none(t)

	c.send(MeetingJob{Op: 3, Kind: "transcribe", SampleCount: 4, Format: SampleFormat})
	c.sendS16(0, 4, 4)
	expectProgress(t, c.recv(), 3, "running")
	call := h.worker.next(t)
	c.send(MeetingCancel{Op: 3})
	if m, ok := c.recv().(Cancelled); !ok || m.Op != 3 {
		t.Fatalf("%#v", m)
	}
	select {
	case <-call.ctx.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("running job not cancelled")
	}
	h.waitBuffered(t, h.meeting.buffered.Load)
	if h.queue.Running() != 0 {
		t.Fatal(h.queue.Running())
	}
}

// Worker state and errors map to channel codes; every failure deletes the
// samples and frees the queue place.
func TestMeetingJobFailures(t *testing.T) {
	h := newMeetingHarness(t)
	user, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)
	op := int64(0)
	start := func() int64 {
		op++
		c.send(MeetingJob{Op: op, Kind: "transcribe", SampleCount: 2, Format: SampleFormat})
		return op
	}
	// Not offered while the worker reported missing models; unavailable
	// while it is starting or restarting.
	for state, code := range map[speech.State]ErrorCode{speech.StateUnavailable: CodeNotOffered, speech.StateRestarting: CodeWorkerUnavailable, speech.StateStarting: CodeWorkerUnavailable} {
		h.worker.setState(state)
		start()
		expectError(t, c.recv(), op, code)
	}
	h.worker.setState(speech.StateReady)
	for _, tc := range []struct {
		result string
		err    error
		code   ErrorCode
	}{
		{"", speech.ErrWorkerUnavailable, CodeWorkerUnavailable},
		{"", &speech.WorkerError{Code: speech.CodeModelUnavailable}, CodeWorkerUnavailable},
		{"", &speech.WorkerError{Code: speech.CodeInvalidAudio}, CodeInvalidMessage},
		{"", &speech.WorkerError{Code: speech.CodeRepetition}, CodeInternal},
		{"", &speech.WorkerError{Code: speech.CodeFailed}, CodeInternal},
		// A result that is not the kind's wire shape, or too large for one
		// control message.
		{`{"text":"x"}`, nil, CodeInternal},
		{`{"text":"` + strings.Repeat("a", 70000) + `","tokens":[],"timings_available":false,"retry_depth":0}`, nil, CodeInternal},
	} {
		start()
		c.sendS16(0, 2, 2)
		expectProgress(t, c.recv(), op, "running")
		h.worker.next(t).reply <- meetingAnswer{result: tc.result, err: tc.err}
		expectError(t, c.recv(), op, tc.code)
		h.waitBuffered(t, h.meeting.buffered.Load)
	}
	if !strings.Contains(h.logs.String(), "result_bytes=") {
		t.Fatal("oversized result not logged")
	}
	// Extra samples are invalid_message.
	start()
	c.sendS16(0, 3, 3)
	expectError(t, c.recv(), op, CodeInvalidMessage)
	h.waitBuffered(t, h.meeting.buffered.Load)
	// busy beyond the user's waiting places.
	for range speech.MaxMeetingWaitingPerUser {
		if _, err := h.queue.Enqueue(user.ID); err != nil {
			t.Fatal(err)
		}
	}
	start()
	expectError(t, c.recv(), op, CodeBusy)
	if h.queue.Running() != 0 {
		t.Fatal("slot held after failures")
	}
}

// ready.capabilities follows the meeting worker: job kinds and models only
// while it is ready.
func TestMeetingCapabilities(t *testing.T) {
	worker := &fakeMeetingWorker{state: speech.StateStarting}
	capabilities := MeetingCapabilities(worker)
	if jobs, models := capabilities(); jobs == nil || len(jobs) != 0 || models != nil {
		t.Fatal(jobs, models)
	}
	worker.setState(speech.StateReady)
	jobs, models := capabilities()
	if strings.Join(jobs, ",") != "diarize,embed,transcribe" || models == nil || models.Voice.Dimension != 256 || models.Transcription.ModelID != "whisper-turbo" {
		t.Fatal(jobs, models)
	}
	operations := Operations{PurposeSession: {"meeting_job": NewMeeting(MeetingConfig{Worker: worker, Queue: speech.NewMeetingQueue(nil)}).Start}}
	h := newHarness(t, operations)
	h.listener.cfg.MeetingCapabilities = capabilities
	_, _, token := h.approved("sub", 1)
	_, first := h.hello(PurposeSession, token)
	ready, ok := first.(Ready)
	if !ok || strings.Join(ready.Capabilities.Ops, ",") != "meeting_job" || len(ready.Capabilities.MeetingJobs) != 3 || ready.Capabilities.Models.Diarization.ModelID != "pyannote" {
		t.Fatalf("%#v", first)
	}
}

// FR-029: the meeting_job, meeting_cancel and live_window operations log no
// transcript text, vocabulary terms, vectors or samples, over every kind,
// an oversized result, a cancelled job and a busy refusal.
func TestMeetingLogsCarryNoContent(t *testing.T) {
	h := newMeetingHarness(t)
	live := &fakeLiveScheduler{calls: make(chan *liveCall, 8)}
	h.listener.cfg.Operations[PurposeSession]["live_window"] = NewLive(LiveConfig{Scheduler: live, Clock: h.clock, Logger: h.listener.cfg.Logger}).Start
	user, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)

	var manifest struct {
		Fixtures []struct {
			Reference string `json:"reference"`
		} `json:"fixtures"`
	}
	readFixture(t, "fixtures/audio/manifest.json", &manifest)
	var corpus struct {
		Vocabulary []struct {
			Canonical string `json:"canonical"`
		} `json:"vocabulary"`
	}
	readFixture(t, "fixtures/vocabulary-boost/tuning.json", &corpus)
	var terms []string
	for _, entry := range corpus.Vocabulary {
		if len(entry.Canonical) >= 4 && entry.Canonical != "MTPLX" && entry.Canonical != "LocalFlow" && len(terms) < 3 {
			terms = append(terms, entry.Canonical)
		}
	}
	quoted, _ := json.Marshal(manifest.Fixtures[0].Reference)
	transcript := `{"text":` + string(quoted) + `,"tokens":[],"timings_available":false,"retry_depth":0}`
	speakers := 2
	op := int64(0)
	for _, tc := range []struct {
		job    MeetingJob
		result string
	}{
		{MeetingJob{Kind: "transcribe", SampleCount: 32, Language: "auto", VocabularyTerms: terms, Pipeline: "w120"}, transcript},
		{MeetingJob{Kind: "diarize", SampleCount: 40000, NumSpeakers: &speakers},
			`{"turns":[{"cluster":0,"start":0,"end":1.5}],"centroids":[{"cluster":0,"vector":[0.123456,-0.25,0.5,0.75]}]}`},
		{MeetingJob{Kind: "embed", SampleCount: 48000}, `{"vector":[0.654321,-0.125,0.375,0.875],"speech_seconds":3}`},
		{MeetingJob{Kind: "transcribe", SampleCount: 32}, `{"text":"` + strings.Repeat(manifest.Fixtures[1].Reference, 1000)[:70000] + `"}`},
	} {
		op++
		tc.job.Op, tc.job.Format = op, SampleFormat
		c.send(tc.job)
		c.sendS16(-1000, tc.job.SampleCount, MaxSampleFrameSamples)
		expectProgress(t, c.recv(), op, "running")
		h.worker.next(t).reply <- meetingAnswer{result: tc.result}
		c.recv()
	}
	// A cancelled job and a busy one.
	op++
	c.send(MeetingJob{Op: op, Kind: "transcribe", SampleCount: 32, Format: SampleFormat, VocabularyTerms: terms})
	c.send(MeetingCancel{Op: op})
	if m, ok := c.recv().(Cancelled); !ok || m.Op != op {
		t.Fatalf("%#v", m)
	}
	for range speech.MaxMeetingWaitingPerUser {
		if _, err := h.queue.Enqueue(user.ID); err != nil {
			t.Fatal(err)
		}
	}
	op++
	c.send(MeetingJob{Op: op, Kind: "transcribe", SampleCount: 32, Format: SampleFormat, VocabularyTerms: terms})
	expectError(t, c.recv(), op, CodeBusy)
	// A live window.
	op++
	c.send(LiveWindow{Op: op, SampleCount: 32, Format: SampleFormat})
	c.sendS16(-1000, 32, 32)
	live.next(t).answer(liveWindowJSON(32, manifest.Fixtures[2].Reference), nil)
	if m, ok := c.recv().(LiveResult); !ok || m.Op != op {
		t.Fatalf("%#v", m)
	}

	logs := h.logs.String()
	for _, want := range []string{"kind=diarize", "code=cancelled", "code=busy", "result_bytes=", "remote live"} {
		if !strings.Contains(logs, want) {
			t.Fatalf("no %q in the log:\n%s", want, logs)
		}
	}
	if report, clean := scanLogs(t, logs); !clean {
		t.Fatalf("log scan:\n%s", report)
	}
}
