package backend

import (
	"context"
	"errors"
	"sync/atomic"
)

// Fallback sends each call to Primary and, when Primary is down or fails
// before producing a result, repeats it on Secondary. Only meeting analysis
// uses it; rewriting stays on the loopback backend (ADR 0021).
type Fallback struct {
	Primary, Secondary *OpenAI
	// primaryDown is set by the latest Probe, so Generate skips a primary the
	// handler just saw as unavailable instead of waiting on it again.
	primaryDown atomic.Bool
	guard       func(context.Context) (context.Context, func(), error)
}

// GuardLocal wraps every Secondary call in guard. The analysis handler passes
// its rewrite-first gate here, so only calls that run on the loopback backend
// wait for or yield to dictation. Call before serving.
func (f *Fallback) GuardLocal(guard func(context.Context) (context.Context, func(), error)) {
	f.guard = guard
}

func (f *Fallback) Probe(ctx context.Context) Info {
	if info := f.Primary.Probe(ctx); info.State == "ready" {
		f.primaryDown.Store(false)
		return info
	}
	f.primaryDown.Store(true)
	return f.Secondary.Probe(ctx)
}

func (f *Fallback) Generate(ctx context.Context, in Input) (Completion, error) {
	if !f.primaryDown.Load() {
		c, err := f.Primary.Generate(ctx, in)
		// A total timeout already spent the caller's budget, and a cancelled
		// or client-gone request has nobody waiting: neither is retried.
		if err == nil || ctx.Err() != nil || !(errors.Is(err, ErrUnavailable) || errors.Is(err, ErrFirstTokenTimeout) || errors.Is(err, ErrBackend)) {
			return c, err
		}
		f.primaryDown.Store(true)
	}
	if f.guard != nil {
		guarded, release, err := f.guard(ctx)
		if err != nil {
			return Completion{}, err
		}
		defer release()
		ctx = guarded
	}
	return f.Secondary.Generate(ctx, in)
}

// ClearCache drops only the local backend's caches; a remote primary is not
// MTPLX and would answer 404.
func (f *Fallback) ClearCache(ctx context.Context) error {
	return f.Secondary.ClearCache(ctx)
}
