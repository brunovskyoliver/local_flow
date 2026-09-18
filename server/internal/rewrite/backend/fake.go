package backend

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Fake is a deterministic in-process SSE backend used by contract tests.
// Configure it before serving. Channels and counters are bounded.
type Fake struct {
	Text, Model       string
	JSONSchema        bool
	Delay             time.Duration
	Requests          chan map[string]any
	Cancelled         chan struct{}
	Probes, Fragments atomic.Int32
	fragmentBytes     int
	once              sync.Once
}

func NewFake() *Fake {
	return &Fake{Text: "Hello.", Model: "test", Requests: make(chan map[string]any, 8), Cancelled: make(chan struct{})}
}
func (f *Fake) Runaway(fragmentBytes int) { f.fragmentBytes = fragmentBytes }
func (f *Fake) cancel()                   { f.once.Do(func() { close(f.Cancelled) }) }
func (f *Fake) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/v1/models" {
		f.Probes.Add(1)
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"id": f.Model, "capabilities": map[string]bool{"json_schema": f.JSONSchema}}}})
		return
	}
	if r.URL.Path != "/v1/chat/completions" {
		http.NotFound(w, r)
		return
	}
	var req map[string]any
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 262144)).Decode(&req) != nil {
		w.WriteHeader(400)
		return
	}
	select {
	case f.Requests <- req:
	default:
	}
	select {
	case <-time.After(f.Delay):
	case <-r.Context().Done():
		f.cancel()
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	fragment := func(text string) bool {
		b, _ := json.Marshal(map[string]any{"model": f.Model, "choices": []any{map[string]any{"delta": map[string]string{"content": text}}}})
		if _, err := fmt.Fprintf(w, "data: %s\n\n", b); err != nil {
			f.cancel()
			return false
		}
		w.(http.Flusher).Flush()
		f.Fragments.Add(1)
		return true
	}
	if f.fragmentBytes > 0 {
		for {
			if !fragment(strings.Repeat("x", f.fragmentBytes)) {
				return
			}
			// Pacing lets tests observe cancellation at the fragment boundary without
			// mistaking bytes already queued in the kernel for adapter consumption.
			select {
			case <-r.Context().Done():
				f.cancel()
				return
			case <-time.After(10 * time.Millisecond):
			}
		}
	}
	text := f.Text
	if _, ok := req["response_format"]; ok {
		b, _ := json.Marshal(text)
		text = string(b)
	}
	if !fragment(text) {
		return
	}
	fmt.Fprint(w, "data: [DONE]\n\n")
	w.(http.Flusher).Flush()
}
