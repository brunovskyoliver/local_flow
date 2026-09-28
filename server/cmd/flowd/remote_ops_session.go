package main

import (
	"context"
	"log"
	"os"
	"strings"
	"sync"

	"localflow/server/internal/accounts"
	"localflow/server/internal/remote"
	"localflow/server/internal/speech"
)

// sessionOperations starts the speech worker supervisor and the window
// scheduler and returns the session channel's operations (dictation and
// rewrite, User Story 1) with a function that stops what they own. The worker
// runs as `<--speech-worker> serve --models <--speech-models>`; while it is
// not ready, dictations are answered worker_unavailable and flowd keeps
// serving. Logs carry IDs, counts, durations, states and codes only: the
// scheduler logs each window's queue time, duration and queue depth, the
// supervisor each worker state change, and the dictation operation each
// session's windows, duration and release latency.
func sessionOperations(ctx context.Context, r remoteConfig, store *accounts.Store,
	watcher *accounts.Watcher, logger *log.Logger) (map[string]remote.OperationStart, func(), error) {
	supervisor := speech.NewSupervisor(speech.SupervisorConfig{
		Command: []string{r.speechWorker, "serve", "--models", r.speechModels},
		Env:     workerEnvironment(os.Environ()),
		Logger:  logger,
	})
	scheduler := speech.NewScheduler(speech.SchedulerConfig{Recognizer: supervisor, Logger: logger})
	runCtx, cancel := context.WithCancel(ctx)
	var running sync.WaitGroup
	running.Add(2)
	go func() {
		defer running.Done()
		supervisor.Run(runCtx)
	}()
	go func() {
		defer running.Done()
		scheduler.Run(runCtx)
	}()
	dictation := remote.NewDictation(remote.DictationConfig{
		Scheduler: remote.SchedulerSessions(scheduler), Models: supervisor, Logger: logger, DebugBusy: r.debugBusy,
	})
	operations := map[string]remote.OperationStart{"dictation_start": dictation.Start}
	if r.rewrite != nil {
		rewriter := remote.NewRewriter(remote.RewriteConfig{Runner: r.rewrite, Windows: scheduler, Logger: logger})
		operations["rewrite"] = rewriter.Start
	}
	var once sync.Once
	stop := func() {
		once.Do(func() {
			cancel()
			running.Wait()
		})
	}
	return operations, stop, nil
}

// workerEnvironment is flowd's environment without its credentials: the
// worker needs neither the rewrite token nor the backend token.
func workerEnvironment(environ []string) []string {
	out := make([]string, 0, len(environ))
	for _, entry := range environ {
		name, _, _ := strings.Cut(entry, "=")
		if name == "LOCALFLOW_REWRITE_TOKEN" || name == "LOCALFLOW_BACKEND_TOKEN" {
			continue
		}
		out = append(out, entry)
	}
	return out
}
