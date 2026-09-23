package backend

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func adapter(t *testing.T, url string, configure func(*Config)) *OpenAI {
	t.Helper()
	c := Config{BaseURL: url + "/v1", Model: "test", FirstTokenTimeout: time.Second, Timeout: 2 * time.Second}
	if configure != nil {
		configure(&c)
	}
	a, err := New(c)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(a.Close)
	return a
}
func TestStreamingAndProbe(t *testing.T) {
	for _, constrained := range []bool{false, true} {
		t.Run(fmt.Sprint(constrained), func(t *testing.T) {
			f := NewFake()
			f.Text = "Keep ⟦E0⟧."
			f.JSONSchema = constrained
			s := httptest.NewServer(f)
			defer s.Close()
			a := adapter(t, s.URL, nil)
			info := a.Probe(context.Background())
			if info.State != "ready" || info.Model != "test" {
				t.Fatal(info)
			}
			var schema map[string]any
			if info.JSONSchema {
				schema = map[string]any{"type": "json_schema", "json_schema": map[string]any{"name": "rewrite_text", "strict": true, "schema": map[string]any{"type": "string"}}}
			}
			result, err := a.Generate(context.Background(), Input{System: "instructions", Text: "input", MaxOutputBytes: 100, ResponseSchema: schema})
			want := f.Text
			if constrained {
				// The fake wraps the text in a JSON string; unwrapping is the
				// caller's job (the rewrite handler does it).
				encoded, _ := json.Marshal(f.Text)
				want = string(encoded)
			}
			if err != nil || result.Text != want || result.FirstTokenMS == nil {
				t.Fatal(result, err)
			}
			request := <-f.Requests
			if request["stream"] != true {
				t.Fatal("streaming not requested")
			}
			_, ok := request["response_format"]
			if ok != constrained {
				t.Fatal("wrong constraint negotiation")
			}
		})
	}
}
func TestTimeoutsAndDelay(t *testing.T) {
	for _, tc := range []struct {
		name                string
		first, total, delay time.Duration
		want                error
	}{
		{"first", 20 * time.Millisecond, time.Second, 100 * time.Millisecond, ErrFirstTokenTimeout},
		{"total", time.Second, 20 * time.Millisecond, 100 * time.Millisecond, ErrTimeout},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := NewFake()
			f.Delay = tc.delay
			s := httptest.NewServer(f)
			defer s.Close()
			a := adapter(t, s.URL, func(c *Config) { c.FirstTokenTimeout = tc.first; c.Timeout = tc.total })
			r, err := a.Generate(context.Background(), Input{Text: "test", MaxOutputBytes: 100})
			if !errors.Is(err, tc.want) || r.Text != "" {
				t.Fatal(r, err)
			}
		})
	}
	f := NewFake()
	s := httptest.NewServer(f)
	defer s.Close()
	a := adapter(t, s.URL, func(c *Config) { c.DebugDelay = 30 * time.Millisecond })
	start := time.Now()
	_, err := a.Generate(context.Background(), Input{Text: "test", MaxOutputBytes: 100})
	if err != nil || time.Since(start) < 30*time.Millisecond {
		t.Fatal(err)
	}
}
func TestRequestTimeoutOverride(t *testing.T) {
	// Per-request deadlines replace the configured budgets in both directions:
	// a shorter first-token bound fires where the config would not, a longer
	// one lets a slow prefill finish where the config would kill it.
	f := NewFake()
	f.Delay = 100 * time.Millisecond
	s := httptest.NewServer(f)
	defer s.Close()
	a := adapter(t, s.URL, func(c *Config) { c.FirstTokenTimeout = time.Second })
	if _, err := a.Generate(context.Background(), Input{Text: "test", MaxOutputBytes: 100, FirstTokenTimeout: 20 * time.Millisecond}); !errors.Is(err, ErrFirstTokenTimeout) {
		t.Fatal(err)
	}
	r, err := a.Generate(context.Background(), Input{Text: "test", MaxOutputBytes: 100, Timeout: 30 * time.Millisecond})
	if !errors.Is(err, ErrTimeout) || r.Text != "" {
		t.Fatal(r, err)
	}
	b := adapter(t, s.URL, func(c *Config) { c.FirstTokenTimeout = 20 * time.Millisecond })
	r, err = b.Generate(context.Background(), Input{Text: "test", MaxOutputBytes: 100, FirstTokenTimeout: time.Second})
	if err != nil || r.Text == "" || r.FirstTokenMS == nil {
		t.Fatal(r, err)
	}
}
func TestUnavailableAndModelBound(t *testing.T) {
	s := httptest.NewServer(NewFake())
	url := s.URL
	s.Close()
	a := adapter(t, url, nil)
	if _, err := a.Generate(context.Background(), Input{Text: "t", MaxOutputBytes: 4}); !errors.Is(err, ErrUnavailable) {
		t.Fatal(err)
	}
	f := NewFake()
	f.Model = strings.Repeat("é", 100)
	s = httptest.NewServer(f)
	defer s.Close()
	a = adapter(t, s.URL, func(c *Config) { c.Model = f.Model })
	if info := a.Probe(context.Background()); len(info.Model) > 128 || info.State != "ready" {
		t.Fatal(info)
	}
}
func TestRunawayCancelsAtBound(t *testing.T) {
	f := NewFake()
	f.Runaway(8)
	s := httptest.NewServer(f)
	defer s.Close()
	a := adapter(t, s.URL, nil)
	r, err := a.Generate(context.Background(), Input{Text: "test", MaxOutputBytes: 32})
	if !errors.Is(err, ErrOutputTooLarge) || r.Text != "" {
		t.Fatal(r, err)
	}
	select {
	case <-f.Cancelled:
	case <-time.After(time.Second):
		t.Fatal("backend not cancelled")
	}
	if n := f.Fragments.Load(); n > 5 {
		t.Fatalf("read past bound: %d", n)
	}
	b := newOutputBuffer(32)
	for i := 0; i < 4; i++ {
		if err := b.append("12345678"); err != nil {
			t.Fatal(err)
		}
	}
	if b.append("x") != ErrOutputTooLarge || cap(b.bytes) > 32 || len(b.bytes) > 32 {
		t.Fatal("unbounded buffer")
	}
}
func TestMalformedAndBoundedSSE(t *testing.T) {
	for _, body := range []string{
		"data: " + strings.Repeat("x", 65537) + "\n\n", "data: nope\n\n", "data: {}\n\n",
		"data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n",
	} {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, body) }))
		a := adapter(t, s.URL, nil)
		out, err := a.Generate(context.Background(), Input{Text: "test", MaxOutputBytes: 100})
		if err == nil || out.Text != "" {
			t.Fatal(out, err)
		}
		s.Close()
	}
}

// finish_reason=length is not a backend fault: the partial text comes back
// flagged Truncated for the caller's validation to judge. Other non-stop
// reasons still fail as backend errors.
func TestFinishLengthDeliversOutput(t *testing.T) {
	body := `data: {"model":"test","choices":[{"delta":{"content":"{\"a\":"},"finish_reason":"length"}]}` + "\n\ndata: [DONE]\n\n"
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, body) }))
	defer s.Close()
	a := adapter(t, s.URL, nil)
	out, err := a.Generate(context.Background(), Input{Text: "t", MaxOutputBytes: 100})
	if err != nil || out.Text != `{"a":` || !out.Truncated {
		t.Fatal(out, err)
	}
	body = `data: {"model":"test","choices":[{"delta":{"content":"x"},"finish_reason":"content_filter"}]}` + "\n\ndata: [DONE]\n\n"
	s2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, body) }))
	defer s2.Close()
	a = adapter(t, s2.URL, nil)
	if _, err = a.Generate(context.Background(), Input{Text: "t", MaxOutputBytes: 100}); !errors.Is(err, ErrBackend) {
		t.Fatal(err)
	}
}

// A backend that rejects response_format gets one retry without it; the
// completion reports whether the schema made it through.
func TestSchemaRejectionRetriesWithout(t *testing.T) {
	var withSchema, withoutSchema atomic.Int32
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/models" {
			_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"id": "test"}}})
			return
		}
		var req map[string]any
		_ = json.NewDecoder(r.Body).Decode(&req)
		w.Header().Set("Content-Type", "text/event-stream")
		if _, ok := req["response_format"]; ok {
			withSchema.Add(1)
			w.WriteHeader(400)
			fmt.Fprint(w, `{"error":{"message":"unsupported JSON Schema: unimplemented keys"}}`)
			return
		}
		withoutSchema.Add(1)
		fmt.Fprint(w, `data: {"model":"test","choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}]}`+"\n\ndata: [DONE]\n\n")
	}))
	defer s.Close()
	a := adapter(t, s.URL, nil)
	schema := map[string]any{"type": "json_schema", "json_schema": map[string]any{"name": "t", "schema": map[string]any{"type": "object"}}}
	out, err := a.Generate(context.Background(), Input{Text: "t", MaxOutputBytes: 100, ResponseSchema: schema})
	if err != nil || out.Text != "hi" || out.SchemaAccepted {
		t.Fatal(out, err)
	}
	if withSchema.Load() != 1 || withoutSchema.Load() != 1 {
		t.Fatalf("calls: %d with schema, %d without", withSchema.Load(), withoutSchema.Load())
	}
	// An unrelated rejection does not trigger the retry; a context overflow
	// is a size refusal the caller splits, not a backend fault.
	s2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		fmt.Fprint(w, `{"error":{"message":"context length exceeded"}}`)
	}))
	defer s2.Close()
	b := adapter(t, s2.URL, nil)
	_, err = b.Generate(context.Background(), Input{Text: "t", MaxOutputBytes: 100, ResponseSchema: schema})
	if !errors.Is(err, ErrTooLarge) || errors.Is(err, ErrBackend) {
		t.Fatal(err)
	}
	// Accepted schemas mark the completion.
	f := NewFake()
	f.JSONSchema = true
	s3 := httptest.NewServer(f)
	defer s3.Close()
	c := adapter(t, s3.URL, nil)
	out, err = c.Generate(context.Background(), Input{Text: "t", MaxOutputBytes: 100, ResponseSchema: schema})
	if err != nil || !out.SchemaAccepted {
		t.Fatal(out, err)
	}
}
func TestCancelMidstream(t *testing.T) {
	f := NewFake()
	f.Runaway(1)
	s := httptest.NewServer(f)
	defer s.Close()
	a := adapter(t, s.URL, nil)
	ctx, cancel := context.WithCancel(context.Background())
	_, err := a.Generate(ctx, Input{Text: "test", MaxOutputBytes: 100, Progress: func(int) error { cancel(); return ctx.Err() }})
	if !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	select {
	case <-f.Cancelled:
	case <-time.After(time.Second):
		t.Fatal("not cancelled")
	}
}

// A counting reader verifies the error-body cap without depending on TCP buffering.
type endlessBody struct{ n int }

func (b *endlessBody) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 'x'
	}
	b.n += len(p)
	return len(p), nil
}
func (b *endlessBody) Close() error { return nil }

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestErrorBodyReadCap(t *testing.T) {
	b := &endlessBody{}
	a := adapter(t, "http://backend", nil)
	a.client.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 500, Body: b, Header: make(http.Header)}, nil
	})
	_, err := a.Generate(context.Background(), Input{Text: "t", MaxOutputBytes: 4})
	if !errors.Is(err, ErrBackend) || b.n > 8192 {
		t.Fatal(err, b.n)
	}
}
func TestProbeStates(t *testing.T) {
	for _, status := range []int{200, 503, 500} {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(status)
			_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"id": "test"}}})
		}))
		a := adapter(t, s.URL, nil)
		info := a.Probe(context.Background())
		want := map[int]string{200: "ready", 503: "loading", 500: "unavailable"}[status]
		if info.State != want {
			t.Fatal(info)
		}
		s.Close()
	}
}

func TestBackendCredentialAndRedirectPolicy(t *testing.T) {
	calls := 0
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Authorization") != "Bearer backend-secret" {
			t.Error("missing backend credential")
		}
		http.Redirect(w, r, "http://127.0.0.1:1/leak", http.StatusTemporaryRedirect)
	}))
	defer s.Close()
	a := adapter(t, s.URL, func(c *Config) { c.Token = "backend-secret" })
	if info := a.Probe(context.Background()); info.State != "unavailable" {
		t.Fatal(info)
	}
	if _, err := a.Generate(context.Background(), Input{Text: "private", MaxOutputBytes: 28}); !errors.Is(err, ErrBackend) {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatal(calls)
	}
}

func TestTotalTimeoutAfterFirstToken(t *testing.T) {
	f := NewFake()
	f.Runaway(1)
	s := httptest.NewServer(f)
	defer s.Close()
	a := adapter(t, s.URL, func(c *Config) { c.Timeout = 80 * time.Millisecond; c.FirstTokenTimeout = 40 * time.Millisecond })
	r, err := a.Generate(context.Background(), Input{Text: "test", MaxOutputBytes: 100})
	if !errors.Is(err, ErrTimeout) || r.Text != "" {
		t.Fatal(r, err)
	}
	select {
	case <-f.Cancelled:
	case <-time.After(time.Second):
		t.Fatal("timeout did not cancel backend")
	}
}

func TestClearCachePostsToOrigin(t *testing.T) {
	var path, auth string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path, auth = r.Method+" "+r.URL.Path, r.Header.Get("Authorization")
	}))
	defer s.Close()
	a := adapter(t, s.URL, func(c *Config) { c.Token = "backend-secret" })
	if err := a.ClearCache(context.Background()); err != nil {
		t.Fatal(err)
	}
	if path != "POST /admin/cache/clear" || auth != "Bearer backend-secret" {
		t.Fatal(path, auth)
	}
}

// A followup rides as a third message, leaving system and user untouched so
// the backend's cached prefix still matches.
func TestFollowupIsTrailingUserMessage(t *testing.T) {
	f := NewFake()
	f.Text = "ok"
	s := httptest.NewServer(f)
	defer s.Close()
	a := adapter(t, s.URL, nil)
	if _, err := a.Generate(context.Background(), Input{System: "sys", Text: "doc", Followup: "fix it", MaxOutputBytes: 100}); err != nil {
		t.Fatal(err)
	}
	messages, _ := (<-f.Requests)["messages"].([]any)
	if len(messages) != 3 {
		t.Fatalf("want 3 messages, got %v", messages)
	}
	last, _ := messages[2].(map[string]any)
	first, _ := messages[1].(map[string]any)
	if last["role"] != "user" || last["content"] != "fix it" || first["content"] != "doc" {
		t.Fatalf("followup misplaced: %v", messages)
	}
}

// A server that refuses a prompt for its size — 413, MTPLX's 507 memory-plan
// refusal, or a 400 naming the context — answers ErrTooLarge; any other 400
// stays a backend error.
func TestSizeRefusal(t *testing.T) {
	for _, tc := range []struct {
		status int
		body   string
		want   error
	}{
		{413, "", ErrTooLarge},
		{507, `{"error":{"message":"prompt does not fit in memory"}}`, ErrTooLarge},
		{400, `{"error":{"message":"This model's maximum context length is 32768 tokens"}}`, ErrTooLarge},
		{400, `{"error":{"message":"temperature must be positive"}}`, ErrBackend},
	} {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(tc.status)
			fmt.Fprint(w, tc.body)
		}))
		_, err := adapter(t, s.URL, nil).Generate(context.Background(), Input{Text: "t", MaxOutputBytes: 100})
		s.Close()
		if !errors.Is(err, tc.want) {
			t.Errorf("%d %s: got %v", tc.status, tc.body, err)
		}
	}
}
