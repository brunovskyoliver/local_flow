package main

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"localflow/server/internal/accounts"
	"localflow/server/internal/remote"
	"localflow/server/internal/speech"
)

// sessionOperations starts the speech and meeting worker supervisors and the
// window scheduler and returns the session channel's operations (dictation,
// rewrite, analysis, live_window and meeting_job), the meeting worker's live
// capabilities and a function that stops what they own. The workers run as
// `<--speech-worker> serve --models <--speech-models>` and
// `<--speech-worker> meeting --models <--meeting-models> --helper
// <--meeting-helper>`; while one is not ready its operations are answered
// worker_unavailable (or not_offered, for a meeting worker without models)
// and flowd keeps serving. With an executable --meeting-processor the handoff
// op stores uploaded meetings under <data-dir>/handoff and runs the processor
// on them. Logs carry IDs, counts, durations, states and codes
// only; the meeting worker's lines carry a "meeting " prefix.
func sessionOperations(ctx context.Context, r remoteConfig, store *accounts.Store,
	watcher *accounts.Watcher, logger *log.Logger) (map[string]remote.OperationStart, func() ([]string, *remote.CapabilityModels), func(), error) {
	supervisor := speech.NewSupervisor(speech.SupervisorConfig{
		Command: []string{r.speechWorker, "serve", "--models", r.speechModels},
		Env:     workerEnvironment(os.Environ()),
		Logger:  logger,
	})
	scheduler := speech.NewScheduler(speech.SchedulerConfig{Recognizer: supervisor, Logger: logger})
	meetingLogger := log.New(logger.Writer(), logger.Prefix()+"meeting ", logger.Flags())
	queue := speech.NewMeetingQueue(meetingLogger)
	meetingWorker := speech.NewSupervisor(speech.SupervisorConfig{
		Command:     []string{r.speechWorker, "meeting", "--models", r.meetingModels, "--helper", r.meetingHelper},
		Env:         workerEnvironment(os.Environ()),
		Logger:      meetingLogger,
		Meeting:     true,
		JobDeadline: speech.MeetingJobDeadline,
		Gate:        queue.InteractiveIdle,
	})
	runs := []func(context.Context){supervisor.Run, scheduler.Run, meetingWorker.Run}
	var handoffs *remote.Handoffs
	if info, err := os.Stat(r.meetingProcessor); r.meetingProcessor != "" && err == nil && info.Mode().IsRegular() && info.Mode()&0o111 != 0 {
		dir := filepath.Join(r.dataDir, "handoff")
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, nil, nil, err
		}
		handoffs = remote.NewHandoffs(remote.HandoffConfig{
			Dir: dir, Processor: r.meetingProcessor, Env: workerEnvironment(os.Environ()), Logger: logger,
			Interactive: queue,
			Args:        []string{"--models", r.meetingModels, "--helper", r.meetingHelper},
		})
		runs = append(runs, handoffs.Run)
	}
	runCtx, cancel := context.WithCancel(ctx)
	var running sync.WaitGroup
	for _, run := range runs {
		running.Add(1)
		go func() {
			defer running.Done()
			run(runCtx)
		}()
	}
	dictation := remote.NewDictation(remote.DictationConfig{
		Scheduler: remote.SchedulerSessions(scheduler), Models: supervisor, Logger: logger, DebugBusy: r.debugBusy,
		Interactive: queue.BeginInteractive,
	})
	live := remote.NewLive(remote.LiveConfig{Scheduler: scheduler, Logger: logger})
	meeting := remote.NewMeeting(remote.MeetingConfig{Worker: meetingWorker, Queue: queue, Logger: meetingLogger})
	operations := map[string]remote.OperationStart{"dictation_start": dictation.Start, "live_window": live.Start, "meeting_job": meeting.Start}
	if r.rewrite != nil {
		rewriter := remote.NewRewriter(remote.RewriteConfig{Runner: r.rewrite, Windows: scheduler, Interactive: queue.BeginInteractive, Logger: logger})
		operations["rewrite"] = rewriter.Start
	}
	if handoffs != nil {
		operations["handoff"] = handoffs.Start
	}
	if r.analysis != nil {
		analyzer := remote.NewAnalyzer(remote.AnalysisConfig{Runner: r.analysis, Logger: logger})
		operations["analysis"] = analyzer.Start
	}
	var once sync.Once
	stop := func() {
		once.Do(func() {
			cancel()
			running.Wait()
		})
	}
	return operations, remote.MeetingCapabilities(meetingWorker), stop, nil
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
