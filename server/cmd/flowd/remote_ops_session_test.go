package main

import (
	"bytes"
	"context"
	"log"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"localflow/server/internal/analysis"
	"localflow/server/internal/remote"
	"localflow/server/internal/rewrite"
)

// The session operations are registered, the worker supervisor keeps running
// without a worker binary, and stop returns promptly. ready.capabilities lists
// exactly the registered operations, with no meeting job kinds or models
// while there is no meeting worker (Feature 018 T011, T031).
func TestSessionOperations(t *testing.T) {
	var logs bytes.Buffer
	logger := log.New(&logs, "", 0)
	r := remoteConfig{speechWorker: filepath.Join(t.TempDir(), "missing-flowd-speech"), speechModels: t.TempDir(),
		meetingModels: t.TempDir(), meetingHelper: filepath.Join(t.TempDir(), "localflow-whisper-engine")}
	ops, meetingCapabilities, stop, err := sessionOperations(context.Background(), r, nil, nil, logger)
	if err != nil {
		t.Fatal(err)
	}
	if ops["dictation_start"] == nil || ops["live_window"] == nil || ops["meeting_job"] == nil || ops["rewrite"] != nil || len(ops) != 3 {
		t.Fatalf("without a rewrite handler: %v", len(ops))
	}
	stopped := make(chan struct{})
	go func() { stop(); close(stopped) }()
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("stop did not return")
	}
	stop()

	r.rewrite = rewrite.NewHandler(rewrite.HandlerConfig{})
	ops, meetingCapabilities, stop, err = sessionOperations(context.Background(), r, nil, nil, logger)
	if err != nil {
		t.Fatal(err)
	}
	stop()
	if ops["dictation_start"] == nil || ops["rewrite"] == nil || ops["analysis"] != nil {
		t.Fatal("rewrite not registered")
	}

	r.analysis = analysis.NewHandler(analysis.HandlerConfig{})
	ops, meetingCapabilities, stop, err = sessionOperations(context.Background(), r, nil, nil, logger)
	if err != nil {
		t.Fatal(err)
	}
	stop()
	capabilities := remote.SessionCapabilities(ops)
	if strings.Join(capabilities.Ops, ",") != "analysis,dictation_start,live_window,meeting_job,rewrite" || len(ops) != 5 {
		t.Fatalf("capabilities %+v", capabilities)
	}
	// No meeting worker binary: no job kinds and no models.
	if jobs, models := meetingCapabilities(); jobs == nil || len(jobs) != 0 || models != nil {
		t.Fatalf("meeting capabilities %v %+v", jobs, models)
	}
	// Both supervisors have stopped, so the log is no longer written.
	if strings.Contains(logs.String(), r.speechModels) || strings.Contains(logs.String(), r.meetingModels) {
		t.Fatal("paths in logs")
	}
}

// The worker does not inherit flowd's credentials.
func TestWorkerEnvironment(t *testing.T) {
	got := workerEnvironment([]string{"HOME=/Users/x", "LOCALFLOW_REWRITE_TOKEN=secret", "LOCALFLOW_BACKEND_TOKEN=secret2", "PATH=/bin"})
	if strings.Join(got, ";") != "HOME=/Users/x;PATH=/bin" {
		t.Fatal(got)
	}
}
