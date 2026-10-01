package remote

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"localflow/server/internal/speech"
)

// fakeLiveScheduler hands each live window to the test, which answers it.
type fakeLiveScheduler struct{ calls chan *liveCall }

type liveCall struct {
	ctx     context.Context
	user    int64
	samples []float32
	reply   chan liveAnswer
}

type liveAnswer struct {
	result speech.WindowResult
	err    error
}

func (f *fakeLiveScheduler) Live(ctx context.Context, user, _ int64, samples []float32) (speech.WindowResult, error) {
	c := &liveCall{ctx: ctx, user: user, samples: samples, reply: make(chan liveAnswer, 1)}
	f.calls <- c
	select {
	case a := <-c.reply:
		return a.result, a.err
	case <-ctx.Done():
		return speech.WindowResult{}, ctx.Err()
	}
}

func (f *fakeLiveScheduler) next(t *testing.T) *liveCall {
	t.Helper()
	select {
	case c := <-f.calls:
		return c
	case <-time.After(5 * time.Second):
		t.Fatal("no live window reached the scheduler")
		return nil
	}
}

func (c *liveCall) answer(window string, err error) {
	c.reply <- liveAnswer{speech.WindowResult{Window: json.RawMessage(window), RecognitionMS: 9}, err}
}

type liveHarness struct {
	*harness
	live      *Live
	scheduler *fakeLiveScheduler
}

func newLiveHarness(t *testing.T) *liveHarness {
	t.Helper()
	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	scheduler := &fakeLiveScheduler{calls: make(chan *liveCall, 8)}
	l := NewLive(LiveConfig{Scheduler: scheduler})
	operations[PurposeSession]["live_window"] = l.Start
	return &liveHarness{h, l, scheduler}
}

// sendS16 sends s16le samples whose values are first, first+1, … in frames
// of at most frame samples.
func (c *testClient) sendS16(first, n, frame int) {
	c.t.Helper()
	for sent := 0; sent < n; {
		size := min(frame, n-sent)
		payload := make([]byte, 2*size)
		for i := range size {
			binary.LittleEndian.PutUint16(payload[2*i:], uint16(int16(first+sent+i)))
		}
		c.sendFrame(Frame{KindSamples, payload})
		sent += size
	}
}

func (h *harness) waitBuffered(t *testing.T, buffered func() int64) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for buffered() != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("%d sample bytes still held", buffered())
		}
		time.Sleep(time.Millisecond)
	}
}

func liveWindowJSON(samples int, text string) string {
	return `{"sample_count":` + itoa(samples) + `,"text":"` + text + `","tokens":[{"text":"` + text + `","start":0.1,"end":0.3}],"boost_hints":[]}`
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

// live_window collects exactly sample_count s16le samples, runs them on the
// dictation worker's live class as f32 and answers live_result with the
// worker's text, tokens and recognition time; the samples are then freed.
func TestLiveWindow(t *testing.T) {
	h := newLiveHarness(t)
	user, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(LiveWindow{Op: 1, SampleCount: 5, Format: SampleFormat, Language: "en"})
	c.sendS16(-2, 5, 3)
	call := h.scheduler.next(t)
	if call.user != user.ID || len(call.samples) != 5 || call.samples[0] != -2.0/32768 || call.samples[4] != 2.0/32768 {
		t.Fatalf("%+v", call)
	}
	if h.live.buffered.Load() == 0 {
		t.Fatal("samples not accounted while running")
	}
	call.answer(liveWindowJSON(5, "hello"), nil)
	m, ok := c.recv().(LiveResult)
	if !ok || m.Op != 1 || m.Window.Text != "hello" || len(m.Window.Tokens) != 1 || m.RecognitionMS != 9 {
		t.Fatalf("%#v", m)
	}
	h.waitBuffered(t, h.live.buffered.Load)
	// The channel serves the next window.
	c.send(LiveWindow{Op: 2, SampleCount: 1, Format: SampleFormat})
	c.sendS16(0, 1, 1)
	h.scheduler.next(t).answer(liveWindowJSON(1, "x"), nil)
	if m, ok := c.recv().(LiveResult); !ok || m.Op != 2 {
		t.Fatalf("%#v", m)
	}
	if strings.Contains(h.logs.String(), "hello") {
		t.Fatal("text in the log")
	}
}

// More samples than sample_count, or a message before the last sample, is
// invalid_message; the samples are freed and nothing reaches the worker.
func TestLiveWindowSampleCount(t *testing.T) {
	h := newLiveHarness(t)
	_, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(LiveWindow{Op: 1, SampleCount: 2, Format: SampleFormat})
	c.sendS16(0, 3, 3)
	expectError(t, c.recv(), 1, CodeInvalidMessage)
	c.send(LiveWindow{Op: 2, SampleCount: 4, Format: SampleFormat})
	c.sendS16(0, 2, 2)
	c.send(MeetingCancel{Op: 2})
	expectError(t, c.recv(), 2, CodeInvalidMessage)
	c.send(LiveWindow{Op: 3, SampleCount: 4, Format: SampleFormat})
	c.sendFrame(Frame{KindAudio, make([]byte, 16)})
	expectError(t, c.recv(), 3, CodeInvalidMessage)
	h.waitBuffered(t, h.live.buffered.Load)
	select {
	case call := <-h.scheduler.calls:
		t.Fatalf("window reached the scheduler: %d samples", len(call.samples))
	default:
	}
}

// Scheduler and worker refusals map to channel codes and free the samples.
func TestLiveWindowFailures(t *testing.T) {
	h := newLiveHarness(t)
	_, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)
	for i, tc := range []struct {
		window string
		err    error
		code   ErrorCode
	}{
		{"", speech.ErrBusy, CodeBusy},
		{"", speech.ErrWorkerUnavailable, CodeWorkerUnavailable},
		{"", &speech.WorkerError{Code: speech.CodeInvalidAudio}, CodeInvalidMessage},
		{"", &speech.WorkerError{Code: speech.CodeFailed}, CodeInternal},
		// A window that does not match its job is the worker's fault.
		{liveWindowJSON(2, "x"), nil, CodeWorkerUnavailable},
		{`{"text":"x"}`, nil, CodeWorkerUnavailable},
	} {
		op := int64(i + 1)
		c.send(LiveWindow{Op: op, SampleCount: 3, Format: SampleFormat})
		c.sendS16(0, 3, 3)
		h.scheduler.next(t).answer(tc.window, tc.err)
		expectError(t, c.recv(), op, tc.code)
		h.waitBuffered(t, h.live.buffered.Load)
	}
}

// Closing the channel while a window waits cancels it and frees the samples.
func TestLiveWindowCancelOnClose(t *testing.T) {
	h := newLiveHarness(t)
	_, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(LiveWindow{Op: 1, SampleCount: 3, Format: SampleFormat})
	c.sendS16(0, 3, 3)
	call := h.scheduler.next(t)
	c.ws.CloseNow()
	select {
	case <-call.ctx.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("live window not cancelled")
	}
	h.waitBuffered(t, h.live.buffered.Load)
	if !errors.Is(call.ctx.Err(), context.Canceled) {
		t.Fatal(call.ctx.Err())
	}
}
