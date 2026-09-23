package backend

import (
	"context"
	"net/http/httptest"
	"testing"
)

// The primary answers while it is up; once it is gone, probe and generate
// both land on the secondary.
func TestFallbackUsesPrimaryThenSecondary(t *testing.T) {
	pf, sf := NewFake(), NewFake()
	pf.Text, sf.Text = "primary", "secondary"
	ps, ss := httptest.NewServer(pf), httptest.NewServer(sf)
	defer ss.Close()
	f := &Fallback{Primary: adapter(t, ps.URL, nil), Secondary: adapter(t, ss.URL, nil)}
	in := Input{Text: "t", MaxOutputBytes: 100}
	if info := f.Probe(context.Background()); info.State != "ready" {
		t.Fatal(info)
	}
	if c, err := f.Generate(context.Background(), in); err != nil || c.Text != "primary" {
		t.Fatal(c, err)
	}
	ps.Close()
	// A generate failure alone moves the call to the secondary.
	if c, err := f.Generate(context.Background(), in); err != nil || c.Text != "secondary" {
		t.Fatal(c, err)
	}
	if info := f.Probe(context.Background()); info.State != "ready" || !f.primaryDown.Load() {
		t.Fatal(info)
	}
	// A cancelled request is not retried on the secondary.
	<-sf.Requests
	f.primaryDown.Store(false)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := f.Generate(ctx, in); err == nil {
		t.Fatal("cancelled request succeeded")
	}
	select {
	case r := <-sf.Requests:
		t.Fatal("secondary received a cancelled request", r)
	default:
	}
}

// The guard wraps only calls that reach the secondary.
func TestFallbackGuardsOnlySecondary(t *testing.T) {
	ps, ss := httptest.NewServer(NewFake()), httptest.NewServer(NewFake())
	defer ss.Close()
	f := &Fallback{Primary: adapter(t, ps.URL, nil), Secondary: adapter(t, ss.URL, nil)}
	guarded := 0
	f.GuardLocal(func(ctx context.Context) (context.Context, func(), error) {
		guarded++
		return ctx, func() {}, nil
	})
	in := Input{Text: "t", MaxOutputBytes: 100}
	if _, err := f.Generate(context.Background(), in); err != nil || guarded != 0 {
		t.Fatal(err, guarded)
	}
	ps.Close()
	if _, err := f.Generate(context.Background(), in); err != nil || guarded != 1 {
		t.Fatal(err, guarded)
	}
}
