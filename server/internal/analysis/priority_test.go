package analysis

import (
	"context"
	"errors"
	"testing"
	"time"
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
