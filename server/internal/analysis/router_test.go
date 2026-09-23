package analysis

import (
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
