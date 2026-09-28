package remote

import (
	"context"
	"encoding/binary"
	"log"
	"math"
	"os"
	"testing"
	"time"

	"localflow/server/internal/speech"
)

// TestRealWorkerWindowsDecode runs the real flowd-speech worker under the
// supervisor and checks that its answers pass the dictation operation's strict
// window decoding. Opt-in, because it needs the built worker and a verified
// model: set LOCALFLOW_SPEECH_WORKER (the executable), LOCALFLOW_SPEECH_MODELS
// (a Models directory without symlinks in its path) and LOCALFLOW_SPEECH_AUDIO
// (16 kHz mono Float32 little-endian samples, at least one second).
func TestRealWorkerWindowsDecode(t *testing.T) {
	worker, models, audio := os.Getenv("LOCALFLOW_SPEECH_WORKER"),
		os.Getenv("LOCALFLOW_SPEECH_MODELS"), os.Getenv("LOCALFLOW_SPEECH_AUDIO")
	if worker == "" || models == "" || audio == "" {
		t.Skip("set LOCALFLOW_SPEECH_WORKER, LOCALFLOW_SPEECH_MODELS and LOCALFLOW_SPEECH_AUDIO")
	}
	raw, err := os.ReadFile(audio)
	if err != nil {
		t.Fatal(err)
	}
	samples := make([]float32, min(len(raw)/4, WindowSamples))
	for i := range samples {
		samples[i] = math.Float32frombits(binary.LittleEndian.Uint32(raw[i*4:]))
	}
	supervisor := speech.NewSupervisor(speech.SupervisorConfig{
		Command: []string{worker, "serve", "--models", models},
		Logger:  log.New(os.Stderr, "supervisor ", 0),
	})
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	go supervisor.Run(ctx)
	for supervisor.State() != speech.StateReady {
		if ctx.Err() != nil {
			t.Fatalf("worker never became ready: %s", supervisor.State())
		}
		time.Sleep(50 * time.Millisecond)
	}
	model, ok := supervisor.Model()
	if !ok || model.Engine != "FluidAudio" || model.ManifestHash == "" {
		t.Fatalf("model identity %+v", model)
	}
	boost := &speech.Boost{Terms: []speech.BoostTerm{{EntryID: "z", Canonical: "Zabbix"}},
		Governed: []string{"zabbix"}}
	for _, job := range []*speech.Boost{nil, boost} {
		result, err := supervisor.Recognize(ctx, speech.Recognition{Samples: samples, Boost: job})
		if err != nil {
			t.Fatalf("recognize: %v", err)
		}
		var w workerWindow
		if err := strictDecode(result.Window, &w); err != nil {
			t.Fatalf("worker window refused: %v", err)
		}
		if w.SampleCount != len(samples) || w.Text == "" || w.Evidence == nil {
			t.Fatalf("window %d samples, %d text bytes, evidence %v", w.SampleCount, len(w.Text), w.Evidence != nil)
		}
		message := WindowResult{Op: 1, Index: 0, SampleStart: 0, SampleCount: w.SampleCount, Text: w.Text,
			Tokens: w.Tokens, Evidence: w.Evidence, BoostHints: w.BoostHints, RecognitionMS: int64(result.RecognitionMS)}
		if _, err := EncodeMessage(message); err != nil {
			t.Fatalf("window_result refused: %v", err)
		}
		t.Logf("window: %d samples, %d ms, %d tokens, %d hints", w.SampleCount, result.RecognitionMS, len(w.Tokens), len(w.BoostHints))
	}
}
