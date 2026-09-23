package analysis

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"
)

// ErrPreempted cancels an in-flight analysis backend call when a rewrite
// arrives and preemption is enabled.
var ErrPreempted = errors.New("preempted")

// Gate implements the rewrite-first rule: a rewrite never waits for analysis;
// an analysis request holding its admission slot waits up to QueueWait while a
// rewrite is in flight, and an in-flight analysis backend call is cancelled
// with ErrPreempted when a rewrite arrives while preemption is on.
type Gate struct {
	queueWait time.Duration
	preempt   bool
	mu        sync.Mutex
	changed   chan struct{}
	rewrites  int
	cancel    context.CancelCauseFunc
	preempted atomic.Int64
}

func NewGate(queueWait time.Duration, preempt bool) *Gate {
	return &Gate{queueWait: queueWait, preempt: preempt, changed: make(chan struct{})}
}

// RewriteStart registers a rewrite; the returned func releases it. Never
// blocks beyond the mutex and preempts the current analysis call if enabled.
func (g *Gate) RewriteStart() func() {
	g.mu.Lock()
	g.rewrites++
	if g.preempt && g.cancel != nil {
		g.cancel(ErrPreempted)
		g.cancel = nil
		g.preempted.Add(1)
	}
	g.mu.Unlock()
	return func() {
		g.mu.Lock()
		g.rewrites--
		close(g.changed)
		g.changed = make(chan struct{})
		g.mu.Unlock()
	}
}

// Enter waits while a rewrite is in flight (up to QueueWait → queue_timeout),
// then returns a context the gate can cancel with ErrPreempted on RewriteStart.
// Call Leave when the backend call finishes.
func (g *Gate) Enter(ctx context.Context) (context.Context, error) {
	timer := time.NewTimer(g.queueWait)
	defer timer.Stop()
	for {
		g.mu.Lock()
		if g.rewrites == 0 {
			ctx, cancel := context.WithCancelCause(ctx)
			g.cancel = cancel
			g.mu.Unlock()
			return ctx, nil
		}
		changed := g.changed
		g.mu.Unlock()
		select {
		case <-changed:
		case <-timer.C:
			return nil, &RequestError{CodeQueueTimeout, "rewrite in flight"}
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
}

// Guard is Enter plus its Leave, for a backend that gates its own local calls.
func (g *Gate) Guard(ctx context.Context) (context.Context, func(), error) {
	ctx, err := g.Enter(ctx)
	if err != nil {
		return nil, nil, err
	}
	return ctx, g.Leave, nil
}

// Leave clears the preemptable call. Safe without Enter.
func (g *Gate) Leave() {
	g.mu.Lock()
	g.cancel = nil
	g.mu.Unlock()
}

// Preemptions counts how many analysis calls a rewrite cancelled.
func (g *Gate) Preemptions() int64 { return g.preempted.Load() }
