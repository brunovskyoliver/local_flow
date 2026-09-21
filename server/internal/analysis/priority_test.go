package analysis

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"localflow/server/internal/backend"
	"localflow/server/internal/rewrite"
)

func TestGateWaitsForRewrite(t *testing.T) {
	g := NewGate(200*time.Millisecond, false)
	release := g.RewriteStart()
	entered := make(chan context.Context, 1)
	go func() {
		ctx, err := g.Enter(context.Background())
		if err != nil {
			entered <- nil
			return
		}
		entered <- ctx
	}()
	select {
	case <-entered:
		t.Fatal("analysis entered while a rewrite ran")
	case <-time.After(50 * time.Millisecond):
	}
	release()
	select {
	case ctx := <-entered:
		if ctx == nil {
			t.Fatal("enter failed after rewrite released")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("enter never returned")
	}
}

func TestGateQueueTimeout(t *testing.T) {
	g := NewGate(50*time.Millisecond, false)
	release := g.RewriteStart()
	defer release()
	_, err := g.Enter(context.Background())
	var re *RequestError
	if !errors.As(err, &re) || re.Code != CodeQueueTimeout {
		t.Fatalf("want queue_timeout, got %v", err)
	}
}

func TestGatePreempts(t *testing.T) {
	g := NewGate(50*time.Millisecond, true)
	ctx, err := g.Enter(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	release := g.RewriteStart()
	defer release()
	select {
	case <-ctx.Done():
		if !errors.Is(context.Cause(ctx), ErrPreempted) {
			t.Fatalf("want preempted cause, got %v", context.Cause(ctx))
		}
	case <-time.After(2 * time.Second):
		t.Fatal("analysis ctx not cancelled")
	}
	if g.Preemptions() != 1 {
		t.Fatalf("preemption count = %d", g.Preemptions())
	}
}

func TestGatePreemptOff(t *testing.T) {
	g := NewGate(50*time.Millisecond, false)
	ctx, err := g.Enter(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	release := g.RewriteStart()
	defer release()
	select {
	case <-ctx.Done():
		t.Fatal("preempt off but ctx cancelled")
	case <-time.After(100 * time.Millisecond):
	}
	if g.Preemptions() != 0 {
		t.Fatal("preemption counted while disabled")
	}
}

func TestGateRewriteNeverBlocked(t *testing.T) {
	g := NewGate(50*time.Millisecond, false)
	if _, err := g.Enter(context.Background()); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		release := g.RewriteStart()
		release()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("rewrite blocked by analysis")
	}
}

// serialBackend models the one model slot flowd shares between analysis and
// rewrite: Generate calls run one at a time and park until a completion is
// queued or the call's context is cancelled.
type serialBackend struct {
	sem         chan struct{}
	completions chan string
	started     chan struct{}
	info        backend.Info
}

func newSerialBackend() *serialBackend {
	return &serialBackend{
		sem:         make(chan struct{}, 1),
		completions: make(chan string, 4),
		started:     make(chan struct{}, 4),
		info:        backend.Info{State: "ready", Model: "test", JSONSchema: false},
	}
}

func (s *serialBackend) Probe(context.Context) backend.Info { return s.info }

func (s *serialBackend) Generate(ctx context.Context, _ backend.Input) (backend.Completion, error) {
	select {
	case s.sem <- struct{}{}:
	case <-ctx.Done():
		return backend.Completion{}, ctx.Err()
	}
	defer func() { <-s.sem }()
	select {
	case s.started <- struct{}{}:
	default:
	}
	select {
	case text := <-s.completions:
		return backend.Completion{Text: text, Model: "test"}, nil
	case <-ctx.Done():
		return backend.Completion{}, context.Cause(ctx)
	}
}

type streamOutcome struct {
	status int
	lines  []map[string]any
	err    error
}

func postStream(url, path string, body []byte) streamOutcome {
	resp, err := http.Post(url+path, "application/json", bytes.NewReader(body))
	if err != nil {
		return streamOutcome{err: err}
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var lines []map[string]any
	for _, line := range bytes.Split(raw, []byte("\n")) {
		if len(line) == 0 {
			continue
		}
		var event map[string]any
		if json.Unmarshal(line, &event) == nil {
			lines = append(lines, event)
		}
	}
	return streamOutcome{status: resp.StatusCode, lines: lines}
}

func lastType(lines []map[string]any, key string) string {
	for i := len(lines) - 1; i >= 0; i-- {
		if v, ok := lines[i][key].(string); ok {
			return v
		}
	}
	return ""
}

func hasCode(lines []map[string]any, code string) bool {
	for _, line := range lines {
		if line["code"] == code {
			return true
		}
	}
	return false
}

// T093: through both real handlers on one shared backend slot. With
// --analysis-preempt on, a rewrite mid-generation cancels the analysis call —
// the stream ends `preempted` and the rewrite never waits.
func TestEndToEndRewritePreemptsAnalysis(t *testing.T) {
	b := newSerialBackend()
	gate := NewGate(30*time.Second, true)
	mux := http.NewServeMux()
	mux.Handle("/v1/analysis/meeting", NewHandler(HandlerConfig{
		Backend: b, ProtocolVersions: []int{1}, Limits: DefaultLimits(), Gate: gate}))
	mux.Handle("/v1/rewrite", rewrite.NewHandler(rewrite.HandlerConfig{
		Backend: b, ProtocolVersions: []int{1}, Gate: gate}))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	body, err := json.Marshal(validRequest())
	if err != nil {
		t.Fatal(err)
	}
	analysisDone := make(chan streamOutcome, 1)
	go func() { analysisDone <- postStream(srv.URL, "/v1/analysis/meeting", body) }()

	// Wait until the analysis backend call holds the model slot.
	select {
	case <-b.started:
	case <-time.After(2 * time.Second):
		t.Fatal("analysis backend call never started")
	}

	rewriteDone := make(chan streamOutcome, 1)
	go func() {
		rewriteDone <- postStream(srv.URL, "/v1/rewrite", []byte(testRewriteBody("hello")))
	}()

	// The rewrite's arrival cancels the analysis backend call mid-generation;
	// the stream ends `preempted` without a result.
	select {
	case out := <-analysisDone:
		if out.err != nil {
			t.Fatalf("analysis request failed: %v", out.err)
		}
		if lastType(out.lines, "type") != "error" || !hasCode(out.lines, "preempted") {
			t.Fatalf("analysis stream did not end preempted: %v", out.lines)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("analysis stream never finished")
	}
	if gate.Preemptions() != 1 {
		t.Fatalf("expected 1 preemption, got %d", gate.Preemptions())
	}

	// The freed slot serves the rewrite immediately — it never waited behind
	// the analysis generation.
	b.completions <- "rewritten"
	select {
	case out := <-rewriteDone:
		if out.err != nil {
			t.Fatalf("rewrite request failed: %v", out.err)
		}
		if out.status != 200 || lastType(out.lines, "event") != "result" {
			t.Fatalf("rewrite not served: status=%d lines=%v", out.status, out.lines)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("rewrite waited behind analysis despite preemption")
	}
}

// T093: with --analysis-preempt off the rewrite waits behind the in-flight
// analysis generation on the shared slot.
func TestEndToEndRewriteWaitsBehindAnalysis(t *testing.T) {
	b := newSerialBackend()
	gate := NewGate(30*time.Second, false)
	mux := http.NewServeMux()
	mux.Handle("/v1/analysis/meeting", NewHandler(HandlerConfig{
		Backend: b, ProtocolVersions: []int{1}, Limits: DefaultLimits(), Gate: gate}))
	mux.Handle("/v1/rewrite", rewrite.NewHandler(rewrite.HandlerConfig{
		Backend: b, ProtocolVersions: []int{1}, Gate: gate}))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	body, err := json.Marshal(validRequest())
	if err != nil {
		t.Fatal(err)
	}
	analysisDone := make(chan streamOutcome, 1)
	go func() { analysisDone <- postStream(srv.URL, "/v1/analysis/meeting", body) }()
	select {
	case <-b.started:
	case <-time.After(2 * time.Second):
		t.Fatal("analysis backend call never started")
	}

	rewriteDone := make(chan streamOutcome, 1)
	go func() {
		rewriteDone <- postStream(srv.URL, "/v1/rewrite", []byte(testRewriteBody("hello")))
	}()

	// While analysis holds the slot the rewrite must not complete.
	select {
	case out := <-rewriteDone:
		t.Fatalf("rewrite finished while analysis held the slot: %v", out.lines)
	case <-time.After(150 * time.Millisecond):
	}

	// The analysis result frees the slot; the rewrite then completes.
	b.completions <- resultLine(t, uuid(0xf00d))
	select {
	case out := <-analysisDone:
		if out.err != nil {
			t.Fatalf("analysis request failed: %v", out.err)
		}
		if lastType(out.lines, "type") != "result" {
			t.Fatalf("analysis did not succeed: %v", out.lines)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("analysis stream never finished")
	}
	b.completions <- "rewritten"
	select {
	case out := <-rewriteDone:
		if out.err != nil {
			t.Fatalf("rewrite request failed: %v", out.err)
		}
		if out.status != 200 || lastType(out.lines, "event") != "result" {
			t.Fatalf("rewrite not served: status=%d lines=%v", out.status, out.lines)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("rewrite never finished after analysis completed")
	}
	if gate.Preemptions() != 0 {
		t.Fatalf("no preemption expected, got %d", gate.Preemptions())
	}
}

// testRewriteBody is a minimal rewrite request — no `priority` field; the
// rewrite path never reads analysis priorities.
func testRewriteBody(text string) string {
	body, _ := json.Marshal(map[string]any{
		"schema_version": 1, "request_id": uuid(0x300), "mode": "clean",
		"text": text, "language_hints": []string{}, "stream_deltas": false,
	})
	return string(body)
}
