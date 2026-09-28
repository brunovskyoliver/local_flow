package remote

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"localflow/server/internal/backend"
	"localflow/server/internal/rewrite"
)

const rewriteTestID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

func rewriteBody(text string) string {
	b, _ := json.Marshal(map[string]any{"schema_version": 1, "request_id": rewriteTestID, "mode": "clean", "text": text,
		"language_hints": []string{}, "stream_deltas": false})
	return string(b)
}

func rewriteBodyV2(text string) string {
	return `{"schema_version":2,"request_id":"` + rewriteTestID + `","mode":"clean","text":` + quote(text) +
		`,"language_hints":[],"stream_deltas":false,"context":{"app_category":"code","field_kind":"code","schema_version":1,"style_hints":true,"terms":[],"truncated":["before_cursor"],"window_title":"a/b"}}`
}

// echoBackend returns the input unchanged; with hold set, each call waits
// for a value on hold or its context.
type echoBackend struct {
	hold    chan struct{}
	calls   atomic.Int32
	started chan struct{}
	before  func() // runs at the start of each Generate
}

func (b *echoBackend) Probe(context.Context) backend.Info {
	return backend.Info{State: "ready", Model: "test-model"}
}

func (b *echoBackend) Generate(ctx context.Context, in backend.Input) (backend.Completion, error) {
	b.calls.Add(1)
	if b.before != nil {
		b.before()
	}
	if b.started != nil {
		b.started <- struct{}{}
	}
	if b.hold != nil {
		select {
		case <-b.hold:
		case <-ctx.Done():
			return backend.Completion{}, ctx.Err()
		}
	}
	return backend.Completion{Text: in.Text, Model: "test-model", DurationMS: 5}, nil
}

// countingGate is the analysis rewrite-first gate.
type countingGate struct{ starts, active atomic.Int32 }

func (g *countingGate) RewriteStart() func() {
	g.starts.Add(1)
	g.active.Add(1)
	return func() { g.active.Add(-1) }
}

// windowGate stands in for the scheduler's WaitForNoDictationWindows.
type windowGate struct {
	mu       sync.Mutex
	free     chan struct{}
	waiting  atomic.Int32
	released atomic.Bool
}

func newWindowGate(free bool) *windowGate {
	g := &windowGate{free: make(chan struct{})}
	if free {
		g.release()
	}
	return g
}

func (g *windowGate) release() {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.released.Load() {
		g.released.Store(true)
		close(g.free)
	}
}

func (g *windowGate) WaitForNoDictationWindows(ctx context.Context) error {
	g.waiting.Add(1)
	defer g.waiting.Add(-1)
	select {
	case <-g.free:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

type rewriteHarness struct {
	*harness
	handler  *rewrite.Handler
	backend  *echoBackend
	gate     *countingGate
	windows  *windowGate
	rewriter *Rewriter
}

func newRewriteHarness(t *testing.T, versions []int, windows *windowGate) *rewriteHarness {
	t.Helper()
	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	b := &echoBackend{}
	gate := &countingGate{}
	handler := rewrite.NewHandler(rewrite.HandlerConfig{Backend: b, Token: "shared-feature-003-token", Shield: true, Gate: gate, ProtocolVersions: versions})
	if windows == nil {
		windows = newWindowGate(true)
	}
	r := NewRewriter(RewriteConfig{Runner: handler, Windows: windows})
	operations[PurposeSession]["rewrite"] = r.Start
	return &rewriteHarness{h, handler, b, gate, windows, r}
}

// events reads rewrite_events for op until the terminal one.
func (c *testClient) rewriteEvents(op int64) []map[string]any {
	c.t.Helper()
	var out []map[string]any
	for {
		m := c.recv()
		event, ok := m.(RewriteEvent)
		if !ok || event.Op != op {
			c.t.Fatalf("got %#v", m)
		}
		var decoded map[string]any
		if err := json.Unmarshal(event.Event, &decoded); err != nil {
			c.t.Fatal(err)
		}
		out = append(out, decoded)
		if kind := decoded["event"]; kind == "result" || kind == "error" {
			return out
		}
	}
}

func httpLines(t *testing.T, handler http.Handler, body string) []map[string]any {
	t.Helper()
	lines, _ := httpRewrite(t, handler, body)
	return lines
}

func httpRewrite(t *testing.T, handler http.Handler, body string) ([]map[string]any, int) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/rewrite", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer shared-feature-003-token")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	var out []map[string]any
	for _, line := range strings.SplitAfter(w.Body.String(), "\n") {
		if line == "" {
			continue
		}
		var decoded map[string]any
		if err := json.Unmarshal([]byte(line), &decoded); err != nil {
			t.Fatalf("%q: %v", line, err)
		}
		out = append(out, decoded)
	}
	return out, w.Code
}

func withoutTiming(events []map[string]any) string {
	for _, e := range events {
		delete(e, "timing")
	}
	b, _ := json.Marshal(events)
	return string(b)
}

// Each NDJSON line of the HTTP route becomes one rewrite_event, ending with
// the result, for v1 and v2 requests.
func TestRewriteEventsMatchHTTPLines(t *testing.T) {
	h := newRewriteHarness(t, nil, nil)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	for i, body := range []string{rewriteBody("Please redeploy the app."), rewriteBodyV2("rename it")} {
		op := int64(i + 1)
		c.send(Rewrite{Op: op, Request: json.RawMessage(body)})
		got := c.rewriteEvents(op)
		want := httpLines(t, h.handler, body)
		if len(got) < 2 || got[0]["event"] != "accepted" || got[len(got)-1]["event"] != "result" {
			t.Fatalf("%v", got)
		}
		if withoutTiming(got) != withoutTiming(want) {
			t.Fatalf("channel %v\nhttp    %v", got, want)
		}
	}
	if h.gate.starts.Load() != 4 {
		t.Fatalf("analysis gate saw %d rewrites", h.gate.starts.Load())
	}
}

// Requests are validated by the rewrite protocol's rules: a malformed request
// is invalid_message, an unknown schema_version unsupported_version, and a
// version this server does not serve is the rewrite error event.
func TestRewriteValidation(t *testing.T) {
	h := newRewriteHarness(t, []int{1}, nil)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(Rewrite{Op: 1, Request: json.RawMessage(`{"schema_version":1,"text":"x"}`)})
	expectError(t, c.recv(), 1, CodeInvalidMessage)
	c.send(Rewrite{Op: 2, Request: json.RawMessage(strings.Replace(rewriteBody("x"), `"schema_version":1`, `"schema_version":7`, 1))})
	expectError(t, c.recv(), 2, CodeUnsupportedVersion)
	c.send(Rewrite{Op: 3, Request: json.RawMessage(rewriteBodyV2("rename it"))})
	events := c.rewriteEvents(3)
	if len(events) != 1 || events[0]["code"] != string(rewrite.CodeUnsupportedVersion) {
		t.Fatalf("%v", events)
	}
	c.send(Rewrite{Op: 4, Request: json.RawMessage(rewriteBody(""))})
	expectError(t, c.recv(), 4, CodeInvalidMessage)
	if h.backend.calls.Load() != 0 {
		t.Fatal("invalid request reached the backend")
	}
	c.send(Rewrite{Op: 5, Request: json.RawMessage(rewriteBody("Fine."))})
	if events := c.rewriteEvents(5); events[len(events)-1]["event"] != "result" {
		t.Fatalf("%v", events)
	}
}

// The handler's limit of 2 in flight is shared with the HTTP route and the
// analysis gate; each user has at most 1 rewrite in flight.
func TestRewriteLimits(t *testing.T) {
	h := newRewriteHarness(t, nil, nil)
	h.backend.hold = make(chan struct{})
	h.backend.started = make(chan struct{}, 8)
	_, _, tokenA := h.approved("a", 1)
	_, _, tokenB := h.approved("b", 2)
	_, _, tokenC := h.approved("c", 3)
	a1, _ := h.hello(PurposeSession, tokenA)
	a2, _ := h.hello(PurposeSession, tokenA)
	b, _ := h.hello(PurposeSession, tokenB)
	cc, _ := h.hello(PurposeSession, tokenC)

	accepted := func(c *testClient, op int64) {
		t.Helper()
		m, ok := c.recv().(RewriteEvent)
		if !ok || m.Op != op || !strings.Contains(string(m.Event), `"event":"accepted"`) {
			t.Fatalf("%#v", m)
		}
	}
	a1.send(Rewrite{Op: 1, Request: json.RawMessage(rewriteBody("One."))})
	accepted(a1, 1)
	<-h.backend.started
	// Same user, other channel: busy.
	a2.send(Rewrite{Op: 1, Request: json.RawMessage(rewriteBody("Two."))})
	expectError(t, a2.recv(), 1, CodeBusy)
	b.send(Rewrite{Op: 1, Request: json.RawMessage(rewriteBody("Three."))})
	accepted(b, 1)
	<-h.backend.started
	if h.gate.active.Load() != 2 {
		t.Fatalf("analysis gate holds %d", h.gate.active.Load())
	}
	// Both slots are taken: the HTTP route and a third user get server_busy.
	if _, status := httpRewrite(t, h.handler, rewriteBody("Four.")); status != http.StatusTooManyRequests {
		t.Fatal(status)
	}
	cc.send(Rewrite{Op: 1, Request: json.RawMessage(rewriteBody("Five."))})
	events := cc.rewriteEvents(1)
	if len(events) != 1 || events[0]["code"] != string(rewrite.CodeServerBusy) {
		t.Fatalf("%v", events)
	}
	close(h.backend.hold)
	for _, c := range []*testClient{a1, b} {
		if events := c.rewriteEvents(1); events[len(events)-1]["event"] != "result" {
			t.Fatalf("%v", events)
		}
	}
	a2.send(Rewrite{Op: 2, Request: json.RawMessage(rewriteBody("Two."))})
	if events := a2.rewriteEvents(2); events[len(events)-1]["event"] != "result" {
		t.Fatalf("%v", events)
	}
}

// A rewrite does not start while any dictation window is queued.
func TestRewriteWaitsForDictationWindows(t *testing.T) {
	windows := newWindowGate(false)
	h := newRewriteHarness(t, nil, windows)
	var early atomic.Bool
	h.backend.before = func() {
		if !windows.released.Load() {
			early.Store(true)
		}
	}
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(Rewrite{Op: 1, Request: json.RawMessage(rewriteBody("Wait for it."))})
	deadline := time.Now().Add(5 * time.Second)
	for windows.waiting.Load() != 1 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if windows.waiting.Load() != 1 || h.gate.starts.Load() != 0 {
		t.Fatal("rewrite did not wait for dictation windows")
	}
	windows.release()
	if events := c.rewriteEvents(1); events[len(events)-1]["event"] != "result" || early.Load() {
		t.Fatalf("%v early=%v", events, early.Load())
	}
}

// token_expired at the operation start.
func TestRewriteTokenExpired(t *testing.T) {
	h := newRewriteHarness(t, nil, nil)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	h.clock.mu.Lock()
	h.clock.now = h.clock.now.Add(15 * time.Minute)
	h.clock.mu.Unlock()
	c.send(Rewrite{Op: 1, Request: json.RawMessage(rewriteBody("x"))})
	expectError(t, c.recv(), 1, CodeTokenExpired)
	if h.backend.calls.Load() != 0 {
		t.Fatal("expired token reached the backend")
	}
}

// Closing the channel cancels a running rewrite and frees the user's slot;
// audio or a stray control message during a rewrite ends it with
// invalid_message.
func TestRewriteEndsWithChannelAndStrayFrames(t *testing.T) {
	h := newRewriteHarness(t, nil, nil)
	h.backend.hold = make(chan struct{})
	h.backend.started = make(chan struct{}, 8)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(Rewrite{Op: 1, Request: json.RawMessage(rewriteBody("One."))})
	c.recv()
	<-h.backend.started
	c.ws.CloseNow()
	deadline := time.Now().Add(5 * time.Second)
	for (h.gate.active.Load() != 0 || h.rewriter.inFlight() != 0) && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if h.gate.active.Load() != 0 || h.rewriter.inFlight() != 0 {
		t.Fatal("closed channel kept the rewrite running")
	}

	for _, frame := range []Frame{{KindAudio, make([]byte, 8)}, control(t, DictationEnd{Op: 1, TotalSamples: 0})} {
		c, _ = h.hello(PurposeSession, token)
		c.send(Rewrite{Op: 1, Request: json.RawMessage(rewriteBody("One."))})
		c.recv()
		<-h.backend.started
		c.sendFrame(frame)
		expectError(t, c.recv(), 1, CodeInvalidMessage)
		deadline = time.Now().Add(5 * time.Second)
		for h.rewriter.inFlight() != 0 && time.Now().Before(deadline) {
			time.Sleep(time.Millisecond)
		}
		if h.rewriter.inFlight() != 0 {
			t.Fatal("rewrite kept running")
		}
		c.ws.CloseNow()
	}
}

// FR-006: the Feature 003 shared rewrite token grants nothing on the remote
// listener, neither as a channel access token nor on any HTTP route.
func TestSharedTokenGrantsNothing(t *testing.T) {
	h := newRewriteHarness(t, nil, nil)
	// Whatever its shape, the shared token is refused at the hello like any
	// unknown value; the channel never becomes ready.
	for _, token := range []string{"shared-feature-003-token", "Bearer shared-feature-003-token",
		"lfa_" + strings.Repeat("S", 43), "lfr_" + strings.Repeat("S", 43)} {
		c, reply := h.hello(PurposeSession, token)
		e, ok := reply.(ErrorMessage)
		if !ok || e.Op != 0 || (e.Code != CodeUnauthorized && e.Code != CodeInvalidMessage) {
			t.Fatalf("%q: %#v", token, reply)
		}
		c.closed()
	}
	for _, target := range []string{"/v1/rewrite", "/v1/rewrite/health", "/v1/analysis/meeting", "/v1/analysis/health", "/v1/remote/channel", "/", "/v1/remote/rewrite"} {
		for _, method := range []string{http.MethodGet, http.MethodPost} {
			req, _ := http.NewRequest(method, h.url+target, strings.NewReader(rewriteBody("x")))
			req.Header.Set("Authorization", "Bearer shared-feature-003-token")
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Close()
			if resp.StatusCode < 400 {
				t.Errorf("%s %s with the shared token: %d", method, target, resp.StatusCode)
			}
		}
	}
	if h.backend.calls.Load() != 0 || h.gate.starts.Load() != 0 {
		t.Fatal("the shared token reached the rewrite handler")
	}
}
