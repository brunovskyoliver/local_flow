package backend

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
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
			result, err := a.Generate(context.Background(), Input{System: "instructions", Text: "input", MaxOutputBytes: 100, JSONSchema: info.JSONSchema})
			if err != nil || result.Text != f.Text || result.FirstTokenMS == nil {
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
