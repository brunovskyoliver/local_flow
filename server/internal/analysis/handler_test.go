package analysis

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"localflow/server/internal/backend"
)

// fakeBackend returns scripted completions or errors and can block.
type fakeBackend struct {
	info        backend.Info
	completions chan string
	err         error
	block       chan struct{}
	requests    chan backend.Input
	probes      atomic.Int32
	truncated   atomic.Bool
}

func newFakeBackend() *fakeBackend {
	return &fakeBackend{
		info:        backend.Info{State: "ready", Model: "test", JSONSchema: false},
		completions: make(chan string, 8),
		requests:    make(chan backend.Input, 8),
	}
}

func (f *fakeBackend) Probe(context.Context) backend.Info {
	f.probes.Add(1)
	return f.info
}

func (f *fakeBackend) Generate(ctx context.Context, in backend.Input) (backend.Completion, error) {
	select {
	case f.requests <- in:
	default:
	}
	if f.block != nil {
		select {
		case <-f.block:
		case <-ctx.Done():
			return backend.Completion{}, context.Cause(ctx)
		}
	}
	if f.err != nil {
		return backend.Completion{}, f.err
	}
	if ctx.Err() != nil {
		return backend.Completion{}, context.Cause(ctx)
	}
	var text string
	select {
	case text = <-f.completions:
	default:
		text = defaultAnswer(in)
	}
	ms := 12
	return backend.Completion{
		Text: text, Model: "test", FirstTokenMS: &ms, DurationMS: 100,
		Truncated: f.truncated.Swap(false),
	}, nil
}

// Answers in the shape each pipeline prompt asks for, grounded in the
// fixture's one segment ("Hello."), in the fixture meeting's Slovak.
const notesAnswer = "## Discussed\n- Hello všetkým účastníkom\n## Decisions\n- Hello\n## Commitments\n- Martin: hello (due: tomorrow)\n## Open questions\n- none\n## Risks\n"
const mergeAnswer = "## Overview\nStretnutie sa začalo pozdravom hello.\n## Topics\n### Pozdrav\n- Všetci povedali hello\n"

func defaultAnswer(in backend.Input) string {
	switch {
	case strings.Contains(in.System, "take notes"):
		return notesAnswer
	case strings.Contains(in.System, "Overview"):
		return mergeAnswer
	default:
		return "1"
	}
}

func requestBody(t *testing.T) []byte {
	t.Helper()
	data, err := json.Marshal(validRequest())
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func serve(t *testing.T, b *fakeBackend, token string) *httptest.Server {
	t.Helper()
	h := NewHandler(HandlerConfig{
		Backend: b, Token: token,
		ProtocolVersions: []int{1}, Limits: DefaultLimits(),
	})
	server := httptest.NewServer(h)
	t.Cleanup(server.Close)
	return server
}

func doPost(url string, body []byte, token string) (int, []map[string]any, http.Header, error) {
	req, err := http.NewRequest("POST", url+"/v1/analysis/meeting", bytes.NewReader(body))
	if err != nil {
		return 0, nil, nil, err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil, nil, err
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
	return resp.StatusCode, lines, resp.Header, nil
}

func post(t *testing.T, url string, body []byte, token string) (int, []map[string]any, http.Header) {
	t.Helper()
	status, lines, header, err := doPost(url, body, token)
	if err != nil {
		t.Fatal(err)
	}
	return status, lines, header
}

func TestHealthEndpoint(t *testing.T) {
	b := newFakeBackend()
	server := serve(t, b, "")
	resp, err := http.Get(server.URL + "/v1/analysis/health")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var health Health
	if json.NewDecoder(resp.Body).Decode(&health) != nil {
		t.Fatal("health body")
	}
	if health.Service != ServiceName || health.ResultSchema != 1 ||
		health.PromptVersions["full"] < 1 || health.Limits.InputBytes != 98304 ||
		health.Caps.ActionItems != 60 {
		t.Fatalf("bad health: %+v", health)
	}
}

func TestUnauthorized(t *testing.T) {
	b := newFakeBackend()
	server := serve(t, b, "secret")
	status, _, _ := post(t, server.URL, requestBody(t), "")
	if status != 401 {
		t.Fatalf("missing auth: %d", status)
	}
	status, _, _ = post(t, server.URL, requestBody(t), "wrong")
	if status != 403 {
		t.Fatalf("wrong auth: %d", status)
	}
}

func TestInvalidRequestCodes(t *testing.T) {
	b := newFakeBackend()
	server := serve(t, b, "")
	status, _, _ := post(t, server.URL, []byte("{"), "")
	if status != 400 {
		t.Fatalf("malformed: %d", status)
	}
	big := make([]byte, MaxRequestBodyBytes+2)
	status, _, _ = post(t, server.URL, big, "")
	if status != 413 {
		t.Fatalf("oversized body: %d", status)
	}
}

func TestHappyPath(t *testing.T) {
	b := newFakeBackend()
	server := serve(t, b, "")
	status, lines, _ := post(t, server.URL, requestBody(t), "")
	if status != 200 {
		t.Fatalf("status %d", status)
	}
	if len(lines) != 2 || lines[0]["type"] != "accepted" || lines[1]["type"] != "result" {
		t.Fatalf("events: %v", lines)
	}
	notes, merge := <-b.requests, <-b.requests
	if notes.MaxOutputTokens != 1024 || merge.MaxOutputTokens != 2048 {
		t.Fatalf("max_tokens = %d, %d", notes.MaxOutputTokens, merge.MaxOutputTokens)
	}
	// The model never gets a JSON schema: it writes notes, the server builds
	// the result (ADR 0022).
	if notes.ResponseSchema != nil || merge.ResponseSchema != nil {
		t.Fatal("analysis sent response_format")
	}
	analysis := lines[1]["analysis"].(map[string]any)
	if analysis["summary"].(map[string]any)["text"] != "Stretnutie sa začalo pozdravom hello." {
		t.Fatalf("summary: %v", analysis["summary"])
	}
	decision := analysis["decisions"].([]any)[0].(map[string]any)
	if decision["sources"].([]any)[0].(map[string]any)["id"] != uuid(2) {
		t.Fatalf("decision not grounded in the segment: %v", decision)
	}
	action := analysis["action_items"].([]any)[0].(map[string]any)
	owner := action["owner"].(map[string]any)
	if owner["kind"] != "participant" || owner["speaker_id"] != uuid(1) {
		t.Fatalf("owner not mapped to the participant: %v", owner)
	}
	// "tomorrow" was never said in the transcript, so it is not a deadline.
	if action["due"].(map[string]any)["state"] != "absent" {
		t.Fatalf("unsaid deadline kept: %v", action["due"])
	}
	if len(analysis["open_questions"].([]any)) != 0 {
		t.Fatal(`"none" became an open question`)
	}
}

func TestResultLineEvents(t *testing.T) {
	b := newFakeBackend()
	server := serve(t, b, "")
	_, lines, _ := post(t, server.URL, requestBody(t), "")
	result := lines[1]
	if result["run_id"] == "" || result["stage"] != "full" ||
		result["prompt_version"].(float64) != 9 ||
		result["pipeline_version"] != "analysis_v2" {
		t.Fatalf("result fields: %v", result)
	}
}

func TestServerBusy(t *testing.T) {
	b := newFakeBackend()
	b.block = make(chan struct{})
	server := serve(t, b, "")
	done := make(chan error, 1)
	go func() {
		_, _, _, err := doPost(server.URL, requestBody(t), "")
		done <- err
	}()
	select {
	case <-b.requests:
	case <-time.After(2 * time.Second):
		t.Fatal("first request never reached backend")
	}
	status, _, _ := post(t, server.URL, requestBody(t), "")
	if status != 429 {
		t.Fatalf("want 429, got %d", status)
	}
	close(b.block)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestBackendFailures(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want string
	}{
		{"unavailable", backend.ErrUnavailable, "backend_unavailable"},
		{"timeout", backend.ErrTimeout, "backend_timeout"},
		{"first token", backend.ErrFirstTokenTimeout, "backend_first_token_timeout"},
		{"backend error", backend.ErrBackend, "backend_error"},
		{"output too large", backend.ErrOutputTooLarge, "output_too_large"},
		// One segment cannot be split further.
		{"too large", backend.ErrTooLarge, "too_large"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := newFakeBackend()
			b.err = tc.err
			server := serve(t, b, "")
			_, lines, _ := post(t, server.URL, requestBody(t), "")
			if len(lines) != 2 || lines[1]["code"] != tc.want {
				t.Fatalf("want %s, got %v", tc.want, lines)
			}
		})
	}
}

// Notes with no discussion in any form leave nothing to summarise.
func TestEmptyNotesAreOutputInvalid(t *testing.T) {
	b := newFakeBackend()
	b.completions <- ""
	b.completions <- ""
	server := serve(t, b, "")
	_, lines, _ := post(t, server.URL, requestBody(t), "")
	if len(lines) != 2 || lines[1]["code"] != "output_invalid" {
		t.Fatalf("want output_invalid, got %v", lines)
	}
}

// Notes without the headings still summarise the part: the prose becomes the
// discussion and the request succeeds.
func TestNotesWithoutHeadingsStillSummarise(t *testing.T) {
	b := newFakeBackend()
	b.completions <- "Everyone said hello."
	b.completions <- "Everyone said hello again."
	server := serve(t, b, "")
	_, lines, _ := post(t, server.URL, requestBody(t), "")
	if len(lines) != 2 || lines[1]["type"] != "result" {
		t.Fatalf("want result, got %v", lines)
	}
	// The retry asked again, at a raised temperature.
	first, retry := <-b.requests, <-b.requests
	if first.Temperature == nil || *first.Temperature != 0 || retry.Temperature == nil || *retry.Temperature != 0.3 {
		t.Fatal("format retry did not raise the temperature")
	}
}

// Regression: the --analysis-timeout / --analysis-first-token-timeout budgets
// must reach the backend call — before, Generate fell back to the rewrite
// adapter's 20 s/5 s deadlines and every chunk died at the 5 s first token.
func TestAnalysisDeadlinesReachBackend(t *testing.T) {
	b := newFakeBackend()
	limits := DefaultLimits()
	limits.Timeout = 123 * time.Second
	limits.FirstTokenTimeout = 45 * time.Second
	h := NewHandler(HandlerConfig{Backend: b, ProtocolVersions: []int{1}, Limits: limits})
	server := httptest.NewServer(h)
	defer server.Close()
	post(t, server.URL, requestBody(t), "")
	request := <-b.requests
	// Every call of the request shares --analysis-timeout, so each gets what
	// is left of it.
	if request.Timeout <= 0 || request.Timeout > limits.Timeout || request.Timeout < limits.Timeout-5*time.Second ||
		request.FirstTokenTimeout != limits.FirstTokenTimeout {
		t.Fatalf("analysis deadlines not forwarded: %+v", request)
	}
}

func TestUnsetDeadlinesGetDefaults(t *testing.T) {
	b := newFakeBackend()
	limits := DefaultLimits()
	limits.Timeout = 0
	limits.FirstTokenTimeout = 0
	h := NewHandler(HandlerConfig{Backend: b, ProtocolVersions: []int{1}, Limits: limits})
	server := httptest.NewServer(h)
	defer server.Close()
	post(t, server.URL, requestBody(t), "")
	request := <-b.requests
	if request.Timeout <= 0 || request.FirstTokenTimeout <= 0 {
		t.Fatalf("unset deadlines stayed zero: %+v", request)
	}
}

func TestQueueTimeout(t *testing.T) {
	b := newFakeBackend()
	b.block = make(chan struct{})
	gate := NewGate(50*time.Millisecond, false)
	h := NewHandler(HandlerConfig{
		Backend: b, ProtocolVersions: []int{1}, Limits: DefaultLimits(), Gate: gate,
	})
	server := httptest.NewServer(h)
	defer server.Close()
	release := gate.RewriteStart()
	done := make(chan []map[string]any, 1)
	go func() {
		_, lines, _ := post(t, server.URL, requestBody(t), "")
		done <- lines
	}()
	select {
	case lines := <-done:
		if len(lines) != 2 || lines[1]["code"] != "queue_timeout" {
			t.Fatalf("want queue_timeout, got %v", lines)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no response")
	}
	release()
}

func TestPreemption(t *testing.T) {
	b := newFakeBackend()
	b.block = make(chan struct{})
	gate := NewGate(50*time.Millisecond, true)
	h := NewHandler(HandlerConfig{
		Backend: b, ProtocolVersions: []int{1}, Limits: DefaultLimits(), Gate: gate,
	})
	server := httptest.NewServer(h)
	defer server.Close()
	done := make(chan []map[string]any, 1)
	go func() {
		_, lines, _ := post(t, server.URL, requestBody(t), "")
		done <- lines
	}()
	select {
	case <-b.requests:
	case <-time.After(2 * time.Second):
		t.Fatal("request never reached backend")
	}
	release := gate.RewriteStart()
	select {
	case lines := <-done:
		if len(lines) != 2 || lines[1]["code"] != "preempted" {
			t.Fatalf("want preempted, got %v", lines)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no response after preemption")
	}
	release()
	if gate.Preemptions() != 1 {
		t.Fatalf("preemptions = %d", gate.Preemptions())
	}
}

func TestLogLine(t *testing.T) {
	b := newFakeBackend()
	var buf bytes.Buffer
	h := NewHandler(HandlerConfig{
		Backend: b, ProtocolVersions: []int{1}, Limits: DefaultLimits(),
		Logger: log.New(&buf, "", 0),
	})
	server := httptest.NewServer(h)
	defer server.Close()
	post(t, server.URL, requestBody(t), "")
	out := buf.String()
	for _, field := range []string{
		"request_id=", "run_id=", "stage=full", "input_bytes=", "output_bytes=",
		"duration_ms=", "queue_ms=", "preemptions=", "attempts=2", "model=test",
		"rejected=due_not_said", "code=succeeded",
	} {
		if !strings.Contains(out, field) {
			t.Errorf("log missing %s: %s", field, out)
		}
	}
	// The log must never carry transcript or model text.
	if strings.Contains(out, "Hello.") || strings.Contains(out, "Sync") {
		t.Errorf("log carries content: %s", out)
	}
}

// T090: a synthesis result carries its partials' items with their sources.
func TestSynthesisSourceUnion(t *testing.T) {
	b := newFakeBackend()
	server := serve(t, b, "")

	partial := minimalResult(uuid(0xf00d), true)
	partial["summary"].(map[string]any)["whole_meeting"] = false
	partial["decisions"] = []any{map[string]any{
		"text": "d", "evidence_class": "explicit",
		"sources": []any{map[string]any{"kind": "segment", "id": uuid(0x333)}}}}
	body := validRequest()
	body["stage"] = "synthesis"
	body["segments"] = nil
	body["notes"] = nil
	body["partials"] = []any{partial}
	data, _ := json.Marshal(body)

	status, lines, _ := post(t, server.URL, data, "")
	if status != 200 || len(lines) != 2 || lines[1]["type"] != "result" {
		t.Fatalf("synthesis rejected: %d %v", status, lines)
	}
	decision := lines[1]["analysis"].(map[string]any)["decisions"].([]any)[0].(map[string]any)
	if decision["sources"].([]any)[0].(map[string]any)["id"] != uuid(0x333) {
		t.Fatalf("synthesis lost the partial's source: %v", decision)
	}
}

type clearingBackend struct {
	*fakeBackend
	cleared chan struct{}
}

func (c *clearingBackend) ClearCache(context.Context) error {
	c.cleared <- struct{}{}
	return nil
}

func TestFullStageClearsBackendCache(t *testing.T) {
	b := &clearingBackend{newFakeBackend(), make(chan struct{}, 1)}
	h := NewHandler(HandlerConfig{Backend: b, ProtocolVersions: []int{1}, Limits: DefaultLimits()})
	server := httptest.NewServer(h)
	t.Cleanup(server.Close)
	if status, _, _ := post(t, server.URL, requestBody(t), ""); status != 200 {
		t.Fatalf("status %d", status)
	}
	select {
	case <-b.cleared:
	case <-time.After(2 * time.Second):
		t.Fatal("full stage did not clear the backend cache")
	}
}

// guardedBackend stands in for backend.Fallback: remote calls skip the gate,
// local ones run inside it.
type guardedBackend struct {
	*fakeBackend
	local bool
	guard func(context.Context) (context.Context, func(), error)
}

func (g *guardedBackend) GuardLocal(guard func(context.Context) (context.Context, func(), error)) {
	g.guard = guard
}

func (g *guardedBackend) Generate(ctx context.Context, in backend.Input) (backend.Completion, error) {
	if g.local {
		guarded, release, err := g.guard(ctx)
		if err != nil {
			return backend.Completion{}, err
		}
		defer release()
		ctx = guarded
	}
	return g.fakeBackend.Generate(ctx, in)
}

// A remote call neither waits for nor yields to a rewrite; a local one still
// does both.
func TestGuardedBackendGatesOnlyLocalCalls(t *testing.T) {
	for _, local := range []bool{false, true} {
		t.Run(fmt.Sprint(local), func(t *testing.T) {
			b := &guardedBackend{fakeBackend: newFakeBackend(), local: local}
			gate := NewGate(50*time.Millisecond, true)
			server := httptest.NewServer(NewHandler(HandlerConfig{
				Backend: b, ProtocolVersions: []int{1}, Limits: DefaultLimits(), Gate: gate,
			}))
			defer server.Close()
			release := gate.RewriteStart()
			defer release()
			_, lines, _ := post(t, server.URL, requestBody(t), "")
			last := lines[len(lines)-1]
			if !local && last["type"] != "result" {
				t.Fatalf("remote call waited for the rewrite: %v", lines)
			}
			if local && (last["code"] != "queue_timeout" || len(lines) != 2) {
				t.Fatalf("local call ignored the rewrite: %v", lines)
			}
		})
	}
	b := &guardedBackend{fakeBackend: newFakeBackend(), local: true}
	b.block = make(chan struct{})
	gate := NewGate(50*time.Millisecond, true)
	server := httptest.NewServer(NewHandler(HandlerConfig{
		Backend: b, ProtocolVersions: []int{1}, Limits: DefaultLimits(), Gate: gate,
	}))
	defer server.Close()
	done := make(chan []map[string]any, 1)
	go func() {
		_, lines, _ := post(t, server.URL, requestBody(t), "")
		done <- lines
	}()
	<-b.requests
	release := gate.RewriteStart()
	defer release()
	if lines := <-done; lines[len(lines)-1]["code"] != "preempted" {
		t.Fatalf("local call was not preempted: %v", lines)
	}
}
