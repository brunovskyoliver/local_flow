package rewrite

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"localflow/server/internal/backend"
)

func decoded(t *testing.T, body string) Request {
	t.Helper()
	req, err := DecodeRequest(strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	return req
}

func collect(lines *[]string) func([]byte) error {
	return func(line []byte) error {
		*lines = append(*lines, string(line))
		return nil
	}
}

func kinds(t *testing.T, lines []string) []string {
	t.Helper()
	var out []string
	for _, line := range lines {
		if !strings.HasSuffix(line, "\n") || strings.Count(line, "\n") != 1 {
			t.Fatalf("not one NDJSON line: %q", line)
		}
		var e map[string]any
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatal(err)
		}
		out = append(out, e["event"].(string))
	}
	return out
}

// Run emits the lines the HTTP route writes, for the same request.
func TestRunMatchesHTTPLines(t *testing.T) {
	for _, tc := range []struct {
		name, input string
		outputs     []string
		code        ErrorCode
	}{
		{"result", "Please redeploy the app.", []string{"Please redeploy the app."}, ""},
		{"spoken retry", "Uh please redeploy the app.", []string{"Here is the text: x", "Please redeploy the app."}, ""},
		{"validation failure", "Please redeploy the app.", []string{" "}, CodeBackendError},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := post(t, NewHandler(HandlerConfig{Backend: &scripted{outputs: tc.outputs}, Shield: true}), testBody(tc.input), "")
			httpLines := strings.SplitAfter(w.Body.String(), "\n")
			httpLines = httpLines[:len(httpLines)-1]
			var lines []string
			code := NewHandler(HandlerConfig{Backend: &scripted{outputs: tc.outputs}, Shield: true}).Run(context.Background(), decoded(t, testBody(tc.input)), collect(&lines))
			if code != tc.code {
				t.Fatal(code)
			}
			got, want := kinds(t, lines), kinds(t, httpLines)
			if strings.Join(got, ",") != strings.Join(want, ",") {
				t.Fatalf("run %v, http %v", got, want)
			}
			last := lines[len(lines)-1]
			if tc.code == "" {
				if resultLine(t, last)["text"] != resultLine(t, httpLines[len(httpLines)-1])["text"] {
					t.Fatal(last)
				}
			} else if !strings.Contains(last, `"code":"`+string(tc.code)+`"`) || last != httpLines[len(httpLines)-1] {
				t.Fatal(last)
			}
		})
	}
}

// blocking holds every Generate until released.
type blocking struct {
	started chan struct{}
	release chan struct{}
}

func (b *blocking) Probe(context.Context) backend.Info {
	return backend.Info{State: "ready", Model: "test"}
}
func (b *blocking) Generate(ctx context.Context, _ backend.Input) (backend.Completion, error) {
	b.started <- struct{}{}
	select {
	case <-b.release:
		return backend.Completion{Text: "Done.", Model: "test"}, nil
	case <-ctx.Done():
		return backend.Completion{}, ctx.Err()
	}
}

type countingGate struct{ active, total atomic.Int32 }

func (g *countingGate) RewriteStart() func() {
	g.active.Add(1)
	g.total.Add(1)
	return func() { g.active.Add(-1) }
}

// HTTP requests and Run share the limit of two in flight and the analysis gate.
func TestRunSharesLimitAndGate(t *testing.T) {
	b := &blocking{started: make(chan struct{}, 4), release: make(chan struct{})}
	gate := &countingGate{}
	h := NewHandler(HandlerConfig{Backend: b, Gate: gate})
	done := make(chan ErrorCode, 2)
	go func() {
		done <- h.Run(context.Background(), decoded(t, testBody("one")), func([]byte) error { return nil })
	}()
	httpDone := make(chan int, 1)
	go func() { httpDone <- post(t, h, testBody("two"), "").Code }()
	for i := 0; i < 2; i++ {
		select {
		case <-b.started:
		case <-time.After(time.Second):
			t.Fatal("rewrites did not start")
		}
	}
	if gate.active.Load() != 2 {
		t.Fatal(gate.active.Load())
	}
	var lines []string
	if code := h.Run(context.Background(), decoded(t, testBody("three")), collect(&lines)); code != CodeServerBusy {
		t.Fatal(code)
	}
	if len(lines) != 1 || !strings.Contains(lines[0], `"event":"error"`) || !strings.Contains(lines[0], `"code":"server_busy"`) || !strings.Contains(lines[0], testID) {
		t.Fatal(lines)
	}
	if w := post(t, h, testBody("four"), ""); w.Code != 429 {
		t.Fatal(w.Code)
	}
	close(b.release)
	if code := <-done; code != "" {
		t.Fatal(code)
	}
	if status := <-httpDone; status != 200 {
		t.Fatal(status)
	}
	if gate.active.Load() != 0 || gate.total.Load() != 2 {
		t.Fatal(gate.active.Load(), gate.total.Load())
	}
}

func TestRunUnsupportedVersion(t *testing.T) {
	h := NewHandler(HandlerConfig{Backend: &scripted{outputs: []string{"x"}}, ProtocolVersions: []int{1}})
	var lines []string
	if code := h.Run(context.Background(), decoded(t, testV2Body("hello")), collect(&lines)); code != CodeUnsupportedVersion {
		t.Fatal(code)
	}
	if len(lines) != 1 || !strings.Contains(lines[0], `"code":"unsupported_version"`) {
		t.Fatal(lines)
	}
}

func TestRunCancelled(t *testing.T) {
	h := NewHandler(HandlerConfig{Backend: &scripted{outputs: []string{"Hello."}}})
	failing := func([]byte) error { return errors.New("peer gone") }
	if code := h.Run(context.Background(), decoded(t, testBody("hello")), failing); code != RunCancelled {
		t.Fatal(code)
	}
	b := &blocking{started: make(chan struct{}, 1), release: make(chan struct{})}
	h = NewHandler(HandlerConfig{Backend: b})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan ErrorCode, 1)
	var lines []string
	go func() { done <- h.Run(ctx, decoded(t, testBody("hello")), collect(&lines)) }()
	<-b.started
	cancel()
	if code := <-done; code != RunCancelled {
		t.Fatal(code)
	}
	if strings.Join(kinds(t, lines), ",") != "accepted" {
		t.Fatal(lines)
	}
}
