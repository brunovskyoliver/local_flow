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
	schemaOK    atomic.Bool
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
	select {
	case text := <-f.completions:
		ms := 12
		return backend.Completion{
			Text: text, Model: "test", FirstTokenMS: &ms, DurationMS: 100,
			Truncated: f.truncated.Swap(false), SchemaAccepted: f.schemaOK.Swap(false),
		}, nil
	case <-ctx.Done():
		return backend.Completion{}, context.Cause(ctx)
	case <-time.After(2 * time.Second):
		return backend.Completion{}, backend.ErrTimeout
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

func resultLine(t *testing.T, meetingID string) string {
	t.Helper()
	data, _ := json.Marshal(minimalResult(meetingID, false))
	return string(data)
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
	meetingID := uuid(0xf00d)
	b.completions <- resultLine(t, meetingID)
	status, lines, _ := post(t, server.URL, requestBody(t), "")
	if status != 200 {
		t.Fatalf("status %d", status)
	}
	if len(lines) != 2 || lines[0]["type"] != "accepted" || lines[1]["type"] != "result" {
		t.Fatalf("events: %v", lines)
	}
	request := <-b.requests
	if request.MaxOutputTokens != 10240 {
		t.Fatalf("max_tokens = %d", request.MaxOutputTokens)
	}
	if request.ResponseSchema != nil {
		t.Fatal("response_format is sent only where the backend advertises json_schema")
	}
}

// The result schema rides response_format only when the probe advertised the
// capability; an unadvertised acceptor can degenerate on a schema this size.
func TestResponseSchemaFollowsAdvertisement(t *testing.T) {
	b := newFakeBackend()
	b.info.JSONSchema = true
	server := serve(t, b, "")
	b.completions <- resultLine(t, uuid(0xf00d))
	post(t, server.URL, requestBody(t), "")
	if (<-b.requests).ResponseSchema == nil {
		t.Fatal("advertised json_schema backend did not get response_format")
	}
}

func TestResultLineEvents(t *testing.T) {
	b := newFakeBackend()
	server := serve(t, b, "")
	meetingID := uuid(0xf00d)
	b.completions <- resultLine(t, meetingID)
	_, lines, _ := post(t, server.URL, requestBody(t), "")
	result := lines[1]
	if result["run_id"] == "" || result["stage"] != "full" ||
		result["prompt_version"].(float64) != 7 ||
		result["pipeline_version"] != "analysis_v1" {
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

func TestOutputInvalidAfterRepair(t *testing.T) {
	b := newFakeBackend()
	b.schemaOK.Store(true)
	b.completions <- "not json"
	b.completions <- "still not json"
	b.completions <- "still not json"
	server := serve(t, b, "")
	_, lines, _ := post(t, server.URL, requestBody(t), "")
	if len(lines) != 2 || lines[1]["code"] != "output_invalid" {
		t.Fatalf("want output_invalid, got %v", lines)
	}
	// Three backend calls: initial + two repairs at rising temperatures.
	first := <-b.requests
	r1 := <-b.requests
	r2 := <-b.requests
	if !strings.Contains(r1.System, "failed validation") || !strings.Contains(r2.System, "failed validation") {
		t.Fatal("repair attempt did not carry the failure")
	}
	if first.Temperature != nil || r1.Temperature == nil || *r1.Temperature != 0.3 ||
		r2.Temperature == nil || *r2.Temperature != 0.5 {
		t.Fatalf("temperature escalation missing: %v %v %v", first.Temperature, r1.Temperature, r2.Temperature)
	}
}

// The schema is in the system prompt on every request, so an unconstrained
// backend's malformed output still earns the contract's repair attempts.
func TestRepairWithoutSchemaConstraint(t *testing.T) {
	b := newFakeBackend()
	b.completions <- "not json"
	b.completions <- resultLine(t, uuid(0xf00d))
	server := serve(t, b, "")
	_, lines, _ := post(t, server.URL, requestBody(t), "")
	if len(lines) != 2 || lines[1]["type"] != "result" {
		t.Fatalf("want repaired result, got %v", lines)
	}
	<-b.requests
	repair := <-b.requests
	if !strings.Contains(repair.System, "failed validation") {
		t.Fatal("repair attempt did not carry the failure")
	}
}

// A completion cut at the token cap is validation's problem, not the
// backend's: the text still fails the schema, the code is output_invalid,
// and a schema-capable backend's repair attempt is told the answer was
// truncated — not merely malformed — so it should answer shorter.
func TestTruncatedOutput(t *testing.T) {
	t.Run("no schema", func(t *testing.T) {
		b := newFakeBackend()
		b.truncated.Store(true)
		b.completions <- `{"meeting_id": "x` // cut mid-object
		b.completions <- `{"meeting_id": "y` // repairs fail the same way
		b.completions <- `{"meeting_id": "y`
		server := serve(t, b, "")
		_, lines, _ := post(t, server.URL, requestBody(t), "")
		if len(lines) != 2 || lines[1]["code"] != "output_invalid" {
			t.Fatalf("want output_invalid, got %v", lines)
		}
	})
	t.Run("repair carries the hint", func(t *testing.T) {
		b := newFakeBackend()
		b.schemaOK.Store(true)
		b.truncated.Store(true)
		b.completions <- `{"meeting_id": "x`
		b.completions <- resultLine(t, uuid(0xf00d))
		server := serve(t, b, "")
		_, lines, _ := post(t, server.URL, requestBody(t), "")
		if len(lines) != 2 || lines[1]["type"] != "result" {
			t.Fatalf("want result, got %v", lines)
		}
		<-b.requests
		repair := <-b.requests
		if !strings.Contains(repair.System, "cut off at the token limit") {
			t.Fatal("repair did not carry the truncation hint")
		}
	})
}

func TestSourceValidation(t *testing.T) {
	b := newFakeBackend()
	result := minimalResult(uuid(0xf00d), false)
	result["decisions"] = []any{map[string]any{
		"text": "d",
		"sources": []any{
			map[string]any{"kind": "segment", "id": uuid(0xbeef)},
		},
	}}
	data, _ := json.Marshal(result)
	b.completions <- string(data)
	b.completions <- string(data) // repair attempts
	b.completions <- string(data)
	server := serve(t, b, "")
	_, lines, _ := post(t, server.URL, requestBody(t), "")
	if len(lines) != 2 || lines[1]["code"] != "source_validation" {
		t.Fatalf("want source_validation, got %v", lines)
	}
}

// An over-cap section is clamped to the schema bound, not rejected — the
// client enforces the same caps, so emitting an unbounded result could never
// persist. The kept entries still validate end to end.
func TestOverCapResult(t *testing.T) {
	b := newFakeBackend()
	result := minimalResult(uuid(0xf00d), false)
	items := []any{}
	for i := 0; i < 41; i++ {
		items = append(items, map[string]any{
			"text": fmt.Sprint("d", i),
			"sources": []any{
				map[string]any{"kind": "segment", "id": uuid(2)},
			},
		})
	}
	result["decisions"] = items
	data, _ := json.Marshal(result)
	b.completions <- string(data)
	server := serve(t, b, "")
	_, lines, _ := post(t, server.URL, requestBody(t), "")
	if len(lines) != 2 || lines[1]["type"] != "result" {
		t.Fatalf("want clamped result, got %v", lines)
	}
	if got := len(lines[1]["analysis"].(map[string]any)["decisions"].([]any)); got != 40 {
		t.Fatalf("want 40 decisions after clamp, got %d", got)
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
	b.completions <- resultLine(t, uuid(0xf00d))
	post(t, server.URL, requestBody(t), "")
	request := <-b.requests
	if request.Timeout != limits.Timeout || request.FirstTokenTimeout != limits.FirstTokenTimeout {
		t.Fatalf("analysis deadlines not forwarded: %+v", request)
	}
}

// The contract's prompts state the schema; without it in the text a backend
// that lacks constrained decoding never learns the required shape.
func TestPromptCarriesResultSchema(t *testing.T) {
	b := newFakeBackend()
	server := serve(t, b, "")
	b.completions <- resultLine(t, uuid(0xf00d))
	post(t, server.URL, requestBody(t), "")
	request := <-b.requests
	for _, marker := range []string{
		"This is the JSON Schema the result must match",
		"never a copy of the schema itself",
		"analysis-result.schema.json", `"meeting_id"`, `"action_items"`,
	} {
		if !strings.Contains(request.System, marker) {
			t.Fatalf("system prompt missing %q", marker)
		}
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
	b.completions <- resultLine(t, uuid(0xf00d))
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
	b.completions <- resultLine(t, uuid(0xf00d))
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
		"duration_ms=", "queue_ms=", "preemptions=", "code=succeeded",
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

// T090: a synthesis result may cite any source in the union of its
// partials' sources — and nothing else.
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

	// uuid(0x333) resolves only through the partial's union.
	result := minimalResult(uuid(0xf00d), false)
	result["decisions"] = []any{map[string]any{
		"text": "d", "evidence_class": "explicit",
		"sources": []any{map[string]any{"kind": "segment", "id": uuid(0x333)}}}}
	rd, _ := json.Marshal(result)
	b.completions <- string(rd)
	status, lines, _ := post(t, server.URL, data, "")
	if status != 200 || len(lines) != 2 || lines[1]["type"] != "result" {
		t.Fatalf("synthesis union source rejected: %d %v", status, lines)
	}

	// A source outside the union is rejected.
	bad := minimalResult(uuid(0xf00d), false)
	bad["decisions"] = []any{map[string]any{
		"text": "d", "evidence_class": "explicit",
		"sources": []any{map[string]any{"kind": "segment", "id": uuid(0x444)}}}}
	bd, _ := json.Marshal(bad)
	b.completions <- string(bd)
	b.completions <- string(bd) // repair attempts
	b.completions <- string(bd)
	_, lines, _ = post(t, server.URL, data, "")
	if len(lines) != 2 || lines[1]["code"] != "source_validation" {
		t.Fatalf("want source_validation, got %v", lines)
	}
}
