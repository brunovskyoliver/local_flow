package remote

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"localflow/server/internal/backend"
	"localflow/server/internal/rewrite"
	"localflow/server/internal/speech"
)

// TestRealConcurrentUsers measures dictation release latency and rewrite time
// for one user alone and for two users at once, through real channels, the
// real flowd-speech worker and the real rewrite backend. Opt-in, for the
// server Mac: set LOCALFLOW_SPEECH_WORKER, LOCALFLOW_SPEECH_MODELS,
// LOCALFLOW_SPEECH_AUDIO (16 kHz mono Float32 little-endian), LOCALFLOW_LOAD_BACKEND
// (an OpenAI-compatible base URL), LOCALFLOW_LOAD_MODEL and, when the backend
// needs one, LOCALFLOW_BACKEND_TOKEN. LOCALFLOW_LOAD_ROUNDS defaults to 10.
//
// Each round, every user streams the clip in real time (1 s frames), all
// release together, and each then rewrites a fixed sentence: the worst case
// of two people finishing a dictation at the same moment.
func TestRealConcurrentUsers(t *testing.T) {
	worker, models, audio := os.Getenv("LOCALFLOW_SPEECH_WORKER"),
		os.Getenv("LOCALFLOW_SPEECH_MODELS"), os.Getenv("LOCALFLOW_SPEECH_AUDIO")
	backendURL, model := os.Getenv("LOCALFLOW_LOAD_BACKEND"), os.Getenv("LOCALFLOW_LOAD_MODEL")
	if worker == "" || models == "" || audio == "" || backendURL == "" || model == "" {
		t.Skip("set LOCALFLOW_SPEECH_WORKER, LOCALFLOW_SPEECH_MODELS, LOCALFLOW_SPEECH_AUDIO, LOCALFLOW_LOAD_BACKEND and LOCALFLOW_LOAD_MODEL")
	}
	rounds := 10
	if n, err := strconv.Atoi(os.Getenv("LOCALFLOW_LOAD_ROUNDS")); err == nil && n > 0 {
		rounds = n
	}
	raw, err := os.ReadFile(audio)
	if err != nil {
		t.Fatal(err)
	}
	samples := make([]float32, min(len(raw)/4, MaxSessionSamples-MaxAudioSamples))
	for i := range samples {
		samples[i] = math.Float32frombits(binary.LittleEndian.Uint32(raw[i*4:]))
	}

	supervisor := speech.NewSupervisor(speech.SupervisorConfig{
		Command: []string{worker, "serve", "--models", models},
		Logger:  log.New(os.Stderr, "supervisor ", 0),
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go supervisor.Run(ctx)
	scheduler := speech.NewScheduler(speech.SchedulerConfig{Recognizer: supervisor})
	go scheduler.Run(ctx)
	queue := speech.NewMeetingQueue(nil)
	llm, err := backend.New(backend.Config{BaseURL: backendURL, Model: model, Token: os.Getenv("LOCALFLOW_BACKEND_TOKEN")})
	if err != nil {
		t.Fatal(err)
	}
	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	t.Cleanup(func() {
		if t.Failed() {
			t.Log(h.logs.String())
		}
	})
	operations[PurposeSession]["dictation_start"] = NewDictation(DictationConfig{
		Scheduler: SchedulerSessions(scheduler), Models: supervisor, Interactive: queue.BeginInteractive}).Start
	operations[PurposeSession]["rewrite"] = NewRewriter(RewriteConfig{
		Runner:  rewrite.NewHandler(rewrite.HandlerConfig{Backend: llm, Shield: true}),
		Windows: scheduler, Interactive: queue.BeginInteractive}).Start
	for deadline := time.Now().Add(2 * time.Minute); supervisor.State() != speech.StateReady; {
		if time.Now().After(deadline) {
			t.Fatalf("worker never became ready: %s", supervisor.State())
		}
		time.Sleep(50 * time.Millisecond)
	}
	tokens := []string{}
	for i := range 2 {
		_, _, token := h.approved(fmt.Sprintf("user-%d", i), byte(i+1))
		tokens = append(tokens, token)
	}
	text := "so I think we should move the release to thursday and ask martin to check the backup before we deploy it to the customer"

	type sample struct{ release, rewrite time.Duration }
	run := func(t *testing.T, users int) []sample {
		var mu sync.Mutex
		var out []sample
		for round := range rounds {
			release := make(chan struct{})
			var streamed sync.WaitGroup
			streamed.Add(users)
			t.Run(fmt.Sprintf("round%d", round), func(t *testing.T) {
				for u := range users {
					t.Run(fmt.Sprintf("user%d", u), func(t *testing.T) {
						t.Parallel()
						c, _ := h.hello(PurposeSession, tokens[u])
						c.t = t
						// A device keeps at most MaxChannelsPerDevice channels.
						defer c.ws.Close(websocket.StatusNormalClosure, "")
						op := int64(1)
						c.send(startMessage(op))
						if _, ok := c.recv().(DictationAccepted); !ok {
							t.Fatal("dictation refused")
						}
						// Real time, as a microphone delivers it.
						started := time.Now()
						for sent := 0; sent < len(samples); sent += MaxAudioSamples {
							chunk := samples[sent:min(sent+MaxAudioSamples, len(samples))]
							payload := make([]byte, 4*len(chunk))
							for i, s := range chunk {
								binary.LittleEndian.PutUint32(payload[4*i:], math.Float32bits(s))
							}
							c.sendFrame(Frame{KindAudio, payload})
							time.Sleep(time.Until(started.Add(time.Duration(sent+len(chunk)) * time.Second / SampleRate)))
						}
						streamed.Done()
						<-release
						end := time.Now()
						c.send(DictationEnd{Op: op, TotalSamples: int64(len(samples))})
						for c.recvLong(t).MessageType() != "dictation_complete" {
						}
						releaseTime := time.Since(end)
						begin := time.Now()
						c.send(Rewrite{Op: 2, Request: json.RawMessage(rewriteBody(text))})
						for {
							e, ok := c.recvLong(t).(RewriteEvent)
							if !ok || strings.Contains(string(e.Event), `"event":"error"`) {
								t.Fatalf("rewrite %#v", e)
							}
							if strings.Contains(string(e.Event), `"event":"result"`) {
								break
							}
						}
						mu.Lock()
						out = append(out, sample{releaseTime, time.Since(begin)})
						mu.Unlock()
					})
				}
				go func() { streamed.Wait(); close(release) }()
			})
		}
		return out
	}
	run(t, 1) // warm-up: model loads and caches
	for _, users := range []int{1, 2} {
		got := run(t, users)
		releases, rewrites := []time.Duration{}, []time.Duration{}
		for _, s := range got {
			releases, rewrites = append(releases, s.release), append(rewrites, s.rewrite)
		}
		t.Logf("users=%d n=%d release %s | rewrite %s", users, len(got), stats(releases), stats(rewrites))
	}
}

// recvLong is recv with room for a worker or model that is busy with the other user.
func (c *testClient) recvLong(t *testing.T) Message {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	_, data, err := c.ws.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	frame, err := c.channel.Open(data)
	if err != nil {
		t.Fatal(err)
	}
	m, err := DecodeMessage(frame.Payload)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func stats(d []time.Duration) string {
	if len(d) == 0 {
		return "none"
	}
	slices.Sort(d)
	at := func(p float64) time.Duration { return d[min(len(d)-1, int(math.Ceil(p*float64(len(d))))-1)] }
	return fmt.Sprintf("median=%dms p95=%dms max=%dms", at(0.5).Milliseconds(), at(0.95).Milliseconds(), d[len(d)-1].Milliseconds())
}
