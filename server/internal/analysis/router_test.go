package analysis

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"localflow/server/internal/backend"
)

func TestRouterPicksPrimaryFromHeaders(t *testing.T) {
	local, err := backend.New(backend.Config{BaseURL: "http://127.0.0.1:1/v1", Model: "local"})
	if err != nil {
		t.Fatal(err)
	}
	r := &Router{Local: local, Gate: NewGate(0, false)}
	req := httptest.NewRequest("POST", "/v1/analysis/meeting", nil)
	if b, err := r.For(req); err != nil || b != BackendAdapter(local) {
		t.Fatal("no headers must use the local backend", b, err)
	}
	req.Header.Set(HeaderPrimaryURL, "http://10.0.0.1:8000/v1")
	if _, err := r.For(req); err == nil {
		t.Fatal("a primary without a model was accepted")
	}
	req.Header.Set(HeaderPrimaryModel, "qwen3-8b")
	req.Header.Set(HeaderPrimaryKey, "secret")
	first, err := r.For(req)
	if err != nil {
		t.Fatal(err)
	}
	if f, ok := first.(*backend.Fallback); !ok || f.Secondary != local {
		t.Fatalf("want a fallback onto the local backend, got %T", first)
	}
	if again, _ := r.For(req); again != first {
		t.Fatal("same primary was rebuilt")
	}
	req.Header.Set(HeaderPrimaryKey, "other")
	if changed, _ := r.For(req); changed == first {
		t.Fatal("a new key reused the old primary")
	}
	req.Header.Set(HeaderPrimaryURL, "ftp://x")
	if _, err := r.For(req); err == nil {
		t.Fatal("invalid URL accepted")
	}
}

// Feature 018 (R9): a custom summaries server with the primary-only header
// fails on its own; the client retries over its channel, never on this Mac.
func TestRouterPrimaryOnlySkipsTheLocalBackend(t *testing.T) {
	local, err := backend.New(backend.Config{BaseURL: "http://127.0.0.1:1/v1", Model: "local"})
	if err != nil {
		t.Fatal(err)
	}
	r := &Router{Local: local, Gate: NewGate(0, false)}
	req := httptest.NewRequest("POST", "/v1/analysis/meeting", nil)
	req.Header.Set(HeaderPrimaryURL, "http://10.0.0.1:8000/v1")
	req.Header.Set(HeaderPrimaryModel, "qwen3-8b")
	req.Header.Set(HeaderPrimaryOnly, "1")
	only, err := r.For(req)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := only.(*backend.OpenAI); !ok || only == BackendAdapter(local) {
		t.Fatalf("want the primary alone, got %T", only)
	}
	req.Header.Del(HeaderPrimaryOnly)
	if b, _ := r.For(req); b == only {
		t.Fatal("without the header the primary-only backend was reused")
	} else if f, ok := b.(*backend.Fallback); !ok || f.Secondary != local {
		t.Fatalf("without the header want the fallback, got %T", b)
	}
	// Primary-only without a primary keeps the local backend: nothing to restrict.
	plain := httptest.NewRequest("POST", "/v1/analysis/meeting", nil)
	plain.Header.Set(HeaderPrimaryOnly, "1")
	if b, err := r.For(plain); err != nil || b != BackendAdapter(local) {
		t.Fatal("primary-only without a primary must use the local backend", b, err)
	}
}

// A primary-only request whose primary is down fails without trying the local
// backend: a real request reaches only the primary.
func TestPrimaryOnlyFailsWithoutTheSecondary(t *testing.T) {
	localHits := 0
	localServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		localHits++
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer localServer.Close()
	local, err := backend.New(backend.Config{BaseURL: localServer.URL + "/v1", Model: "local"})
	if err != nil {
		t.Fatal(err)
	}
	r := &Router{Local: local, Gate: NewGate(0, false)}
	req := httptest.NewRequest("POST", "/v1/analysis/meeting", nil)
	req.Header.Set(HeaderPrimaryURL, "http://127.0.0.1:1/v1")
	req.Header.Set(HeaderPrimaryModel, "m")
	req.Header.Set(HeaderPrimaryOnly, "1")
	b, err := r.For(req)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := b.Generate(context.Background(), backend.Input{
		Text: "x", MaxOutputBytes: 64,
	}); err == nil {
		t.Fatal("a down primary answered")
	}
	if info := b.Probe(context.Background()); info.State == "ready" {
		t.Fatal("a down primary probed ready")
	}
	if localHits != 0 {
		t.Fatalf("the local backend was contacted %d times", localHits)
	}
}
