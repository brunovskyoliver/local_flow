package remote

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"sync"
	"testing"

	"localflow/server/internal/accounts"
	"localflow/server/internal/rewrite"
	"localflow/server/internal/speech"
)

// isolationHarness runs the real dictation and rewrite operations over the
// real scheduler, with a fake worker that records every job, for two users.
type isolationHarness struct {
	*harness
	recognizer *recordingRecognizer
	backend    *echoBackend
	tokenA     string
	tokenB     string
	userA      accounts.User
	userB      accounts.User
	deviceA    accounts.Device
	deviceB    accounts.Device
	refreshB   string
	analysis   *fakeAnalysis
	live       *fakeLiveScheduler
	meeting    *fakeMeetingWorker
	attempts   int // cross_user_attempt rows expected for alice

	mu       sync.Mutex
	received map[string][]string // messages each user's clients received, as JSON
}

func newIsolationHarness(t *testing.T) *isolationHarness {
	t.Helper()
	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	h.listener.cfg.Audit = func(entry accounts.AuditEntry) {
		if err := h.store.Audit(context.Background(), entry); err != nil {
			t.Error(err)
		}
	}
	recognizer := &recordingRecognizer{}
	scheduler := speech.NewScheduler(speech.SchedulerConfig{Recognizer: recognizer})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go scheduler.Run(ctx)
	b := &echoBackend{}
	handler := rewrite.NewHandler(rewrite.HandlerConfig{Backend: b, Shield: true})
	operations[PurposeSession]["dictation_start"] = NewDictation(DictationConfig{
		Scheduler: SchedulerSessions(scheduler), Models: &fakeModels{model: testModel(), ok: true}, Clock: h.clock}).Start
	operations[PurposeSession]["rewrite"] = NewRewriter(RewriteConfig{Runner: handler, Windows: scheduler}).Start
	// Feature 018 ops, over fakes that hand each request to the test.
	fa := newFakeAnalysis(`{"type":"result"}`)
	fa.hold = make(chan struct{})
	operations[PurposeSession]["analysis"] = NewAnalyzer(AnalysisConfig{Runner: fa, Clock: h.clock}).Start
	live := &fakeLiveScheduler{calls: make(chan *liveCall, 8)}
	operations[PurposeSession]["live_window"] = NewLive(LiveConfig{Scheduler: live, Clock: h.clock}).Start
	meeting := &fakeMeetingWorker{calls: make(chan *meetingCall, 8), state: speech.StateReady}
	operations[PurposeSession]["meeting_job"] = NewMeeting(MeetingConfig{Worker: meeting, Queue: speech.NewMeetingQueue(nil), Clock: h.clock}).Start
	x := &isolationHarness{harness: h, recognizer: recognizer, backend: b, analysis: fa, live: live, meeting: meeting,
		received: map[string][]string{}}
	x.userA, x.deviceA, x.tokenA = h.approved("alice", 1)
	x.userB, x.deviceB, x.tokenB = h.approved("bob", 2)
	refresh, _, err := h.store.IssueRefresh(context.Background(), x.deviceB.ID)
	if err != nil {
		t.Fatal(err)
	}
	x.refreshB = refresh
	return x
}

// recv records what a user's client received.
func (x *isolationHarness) recv(user string, c *testClient) Message {
	x.t.Helper()
	m := c.recv()
	data, _ := EncodeMessage(m)
	x.mu.Lock()
	x.received[user] = append(x.received[user], string(data))
	x.mu.Unlock()
	return m
}

func (x *isolationHarness) recvSkippingProgress(user string, c *testClient) Message {
	x.t.Helper()
	for {
		if m := x.recv(user, c); m.MessageType() != "progress" {
			return m
		}
	}
}

// crossUserRows counts cross_user_attempt audit rows by actor.
func (x *isolationHarness) crossUserRows() map[string]int {
	x.t.Helper()
	entries, err := x.store.AuditLog(context.Background(), 1000)
	if err != nil {
		x.t.Fatal(err)
	}
	out := map[string]int{}
	for _, e := range entries {
		if e.Action == "cross_user_attempt" {
			if e.Outcome != string(CodeInvalidMessage) {
				x.t.Fatalf("audit outcome %s", e.Outcome)
			}
			out[e.Actor]++
		}
	}
	return out
}

// expectRefused sends frames on a fresh channel of alice's and expects
// error{op, code}; audited says whether a cross_user_attempt row is due.
func (x *isolationHarness) expectRefused(name string, op int64, code ErrorCode, audited bool, frames ...Frame) {
	x.t.Helper()
	ca, _ := x.hello(PurposeSession, x.tokenA)
	for _, frame := range frames {
		ca.sendFrame(frame)
	}
	// Replies to alice's own operations (accepted, progress, cancelled)
	// come first.
	m := x.recv("alice", ca)
	for m.MessageType() != "error" {
		m = x.recv("alice", ca)
	}
	e, ok := m.(ErrorMessage)
	if !ok || e.Code != code || e.Op != op {
		x.t.Fatalf("%s: %#v", name, m)
	}
	if audited {
		x.attempts++
	}
	if got := x.crossUserRows()[accounts.DeviceActor(x.deviceA.ID)]; got != x.attempts {
		x.t.Fatalf("%s: %d cross_user_attempt rows, want %d", name, got, x.attempts)
	}
	ca.ws.CloseNow()
}

// sendSigned sends n samples with values sign*(first+i+1): alice's audio is
// positive, bob's negative, so every job shows whose audio it carries.
func sendSigned(c *testClient, sign float32, first, n int) {
	c.t.Helper()
	for sent := 0; sent < n; {
		size := min(MaxAudioSamples, n-sent)
		payload := make([]byte, 4*size)
		for i := range size {
			binary.LittleEndian.PutUint32(payload[4*i:], math.Float32bits(sign*float32(first+sent+i+1)))
		}
		c.sendFrame(Frame{KindAudio, payload})
		sent += size
	}
}

func boostFor(term string) *Boost {
	return &Boost{Terms: []BoostTerm{{EntryID: "id-" + term, Canonical: term}}, Governed: []string{strings.ToLower(term)}}
}

func p256Key(t *testing.T) []byte {
	t.Helper()
	key, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return key.PublicKey().Bytes()
}

// SC-006: concurrent dictations of two users never mix audio, terms or
// results, and every attempt to reach the other user's operation, token or
// session is refused like a nonexistent value, with a cross_user_attempt
// audit row for identifiers on an authenticated channel.
func TestIsolationTwoUsers(t *testing.T) {
	x := newIsolationHarness(t)

	// Bob starts a dictation (op 2 on his channel) and keeps it open.
	cb, _ := x.hello(PurposeSession, x.tokenB)
	start := startMessage(2)
	start.Boost = boostFor("BetaTerm")
	cb.send(start)
	if _, ok := x.recv("bob", cb).(DictationAccepted); !ok {
		t.Fatal("bob refused")
	}
	sendSigned(cb, -1, 0, 1000)

	expectRefused := x.expectRefused
	aliceStart := startMessage(1)
	aliceStart.Boost = boostFor("AlphaTerm")
	// Alice's audio is positive, like all of hers.
	audio := Frame{KindAudio, make([]byte, 4*100)}
	for i := range 100 {
		binary.LittleEndian.PutUint32(audio.Payload[4*i:], math.Float32bits(float32(i+1)))
	}

	// Bob's op on alice's idle channel: every operation message type.
	expectRefused("dictation_end with bob's op", 0, CodeInvalidMessage, true, control(t, DictationEnd{Op: 2, TotalSamples: 1000}))
	expectRefused("dictation_cancel with bob's op", 0, CodeInvalidMessage, true, control(t, DictationCancel{Op: 2}))
	// Bob's op while alice's own dictation (op 1) runs.
	expectRefused("dictation_end with bob's op during alice's dictation", 1, CodeInvalidMessage, true,
		control(t, aliceStart), control(t, DictationEnd{Op: 2, TotalSamples: 1000}))
	expectRefused("dictation_cancel with bob's op during alice's dictation", 1, CodeInvalidMessage, true,
		control(t, aliceStart), control(t, DictationCancel{Op: 2}))
	expectRefused("dictation_start with a stale op", 0, CodeInvalidMessage, true,
		control(t, aliceStart), control(t, DictationCancel{Op: 1}), control(t, startMessage(1)))
	expectRefused("rewrite during alice's dictation", 1, CodeInvalidMessage, true,
		control(t, aliceStart), control(t, Rewrite{Op: 2, Request: json.RawMessage(rewriteBody("x"))}))
	// Account messages with bob's credentials on a session channel: wrong
	// purpose.
	expectRefused("refresh with bob's refresh token", 0, CodeInvalidMessage, true,
		control(t, Refresh{Op: 1, RefreshToken: x.refreshB, Signature: make([]byte, 64)}))
	expectRefused("enroll with bob's identity", 0, CodeInvalidMessage, true,
		control(t, Enroll{Op: 1, Provider: "apple", IDToken: "aaa.bbb.ccc", DeviceName: "Bob's Mac", DeviceKey: p256Key(t), Signature: make([]byte, 64)}))
	// Messages naming bob's token or user are schema violations (no such
	// field), refused before any operation sees them.
	expectRefused("dictation_start carrying bob's token", 0, CodeInvalidMessage, false,
		Frame{KindControl, []byte(`{"schema_version":1,"type":"dictation_start","op":1,"format":"f32le","sample_rate":16000,"access_token":"` + x.tokenB + `"}`)})
	expectRefused("rewrite carrying bob's user id", 0, CodeInvalidMessage, false,
		Frame{KindControl, []byte(fmt.Sprintf(`{"schema_version":1,"type":"rewrite","op":1,"request":{},"user":%d}`, x.userB.ID))})
	// Audio outside alice's own session: no dictation, after a refused
	// start, after her dictation ended.
	expectRefused("audio with no dictation", 0, CodeInvalidMessage, false, audio)
	ca, _ := x.hello(PurposeSession, x.tokenA)
	ca.send(aliceStart)
	ca.sendFrame(audio)
	ca.send(DictationEnd{Op: 1, TotalSamples: 100})
	for x.recvSkippingProgress("alice", ca).MessageType() != "dictation_complete" {
	}
	ca.sendFrame(audio)
	expectError(t, x.recv("alice", ca), 0, CodeInvalidMessage)
	ca.ws.CloseNow()

	// Tokens: bob's refresh token as an access token, and a malformed one,
	// get what a nonexistent value of the same shape gets.
	nonexistent := func(token string) ErrorCode {
		_, m := x.hello(PurposeSession, token)
		return m.(ErrorMessage).Code
	}
	if got, want := nonexistent(x.refreshB), nonexistent("lfr_"+strings.Repeat("Q", 43)); got != want {
		t.Fatalf("bob's refresh token as access token: %s, nonexistent: %s", got, want)
	}

	// Bob's dictation is untouched: it completes with his own audio only.
	sendSigned(cb, -1, 1000, WindowSamples)
	total := 1000 + WindowSamples
	cb.send(DictationEnd{Op: 2, TotalSamples: int64(total)})
	for i := range 2 {
		r, ok := x.recvSkippingProgress("bob", cb).(WindowResult)
		if !ok || r.Op != 2 || r.Index != i {
			t.Fatalf("bob result %d: %#v", i, r)
		}
	}
	if m, ok := x.recvSkippingProgress("bob", cb).(DictationComplete); !ok || m.Windows != 2 {
		t.Fatalf("%#v", m)
	}
	if x.crossUserRows()[accounts.DeviceActor(x.deviceB.ID)] != 0 {
		t.Fatal("bob's channel was audited")
	}

	// Concurrent dictations and rewrites of both users.
	ca, _ = x.hello(PurposeSession, x.tokenA)
	var wg sync.WaitGroup
	run := func(user string, c *testClient, sign float32, term string, op int64) {
		defer wg.Done()
		start := startMessage(op)
		start.Boost = boostFor(term)
		c.send(start)
		x.recv(user, c)
		n := WindowSamples + 5000
		sendSigned(c, sign, 0, n)
		c.send(DictationEnd{Op: op, TotalSamples: int64(n)})
		for {
			if m := x.recvSkippingProgress(user, c); m.MessageType() == "dictation_complete" {
				break
			} else if m.MessageType() != "window_result" {
				t.Errorf("%s: %#v", user, m)
				return
			}
		}
		c.send(Rewrite{Op: op + 1, Request: json.RawMessage(rewriteBody(term + " rewrite text."))})
		for {
			m := x.recv(user, c)
			if e, ok := m.(RewriteEvent); !ok {
				t.Errorf("%s: %#v", user, m)
				return
			} else if strings.Contains(string(e.Event), `"event":"result"`) || strings.Contains(string(e.Event), `"event":"error"`) {
				return
			}
		}
	}
	wg.Add(2)
	go run("alice", ca, 1, "AlphaTerm", 10)
	go run("bob", cb, -1, "BetaTerm", 10)
	wg.Wait()

	// Every job carried one user's audio and that user's terms only.
	jobs := x.recognizer.recorded()
	if len(jobs) < 6 {
		t.Fatalf("%d jobs", len(jobs))
	}
	for i, job := range jobs {
		positive := job.Samples[0] > 0
		for _, s := range job.Samples {
			if (s > 0) != positive {
				t.Fatalf("job %d mixes both users' audio", i)
			}
		}
		want := "BetaTerm"
		if positive {
			want = "AlphaTerm"
		}
		if job.Boost == nil || len(job.Boost.Terms) != 1 || job.Boost.Terms[0].Canonical != want {
			t.Fatalf("job %d (positive=%v) carried terms %#v", i, positive, job.Boost)
		}
	}
	// No response to one user carries the other's audio, text, terms or
	// results.
	x.mu.Lock()
	defer x.mu.Unlock()
	for user, foreign := range map[string][]string{"alice": {"BetaTerm", "first=-"}, "bob": {"AlphaTerm", "first=1", "first=2"}} {
		if len(x.received[user]) == 0 {
			t.Fatalf("%s received nothing", user)
		}
		for _, message := range x.received[user] {
			for _, marker := range foreign {
				if strings.Contains(message, marker) {
					t.Fatalf("%s received %q: %s", user, marker, message)
				}
			}
		}
	}
}

// A scheduler session only ever yields its own windows: two users' sessions
// submitted in interleaved order get back their own samples and terms.
func TestIsolationSchedulerSessions(t *testing.T) {
	recognizer := &recordingRecognizer{gate: make(chan struct{})}
	scheduler := speech.NewScheduler(speech.SchedulerConfig{Recognizer: recognizer})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go scheduler.Run(ctx)
	a, b := scheduler.Open(1, 1), scheduler.Open(2, 2)
	window := func(sign float32, index int, term string) speech.Window {
		samples := make([]float32, 10)
		for i := range samples {
			samples[i] = sign * float32(index*10+i+1)
		}
		return speech.Window{Index: index, SampleStart: index * 10, Samples: samples,
			Boost: &speech.Boost{Terms: []speech.BoostTerm{{EntryID: "id-" + term, Canonical: term}}, Governed: []string{}}}
	}
	for i := range 2 {
		if err := a.Submit(window(1, i, "AlphaTerm")); err != nil {
			t.Fatal(err)
		}
		if err := b.Submit(window(-1, i, "BetaTerm")); err != nil {
			t.Fatal(err)
		}
	}
	close(recognizer.gate)
	for _, tc := range []struct {
		session *speech.Session
		marker  string
		foreign string
	}{{a, "AlphaTerm", "BetaTerm"}, {b, "BetaTerm", "AlphaTerm"}} {
		for i := range 2 {
			out := <-tc.session.Results()
			text := string(out.Result.Window)
			if out.Err != nil || out.Index != i || !strings.Contains(text, tc.marker) || strings.Contains(text, tc.foreign) {
				t.Fatalf("%s window %d: %v %s", tc.marker, i, out.Err, text)
			}
		}
	}
}

// quickOp ends at its first control message: it closes Done, then answers,
// as the dictation and rewrite operations do.
type quickOp struct {
	conn *Conn
	op   int64
	done chan struct{}
}

func (q *quickOp) Control(ctx context.Context, _ Message) error {
	close(q.done)
	return q.conn.Send(ctx, DictationComplete{Op: q.op})
}
func (q *quickOp) Audio(context.Context, []byte) error { return nil }
func (q *quickOp) Done() <-chan struct{}               { return q.done }
func (q *quickOp) Close()                              {}

// Regression (T085): the next operation, sent the moment the client sees the
// previous one's last reply, is not refused as a stray op because the
// listener has yet to notice the previous operation ended; and no
// cross_user_attempt row is written for it.
func TestNextOperationRightAfterTheLastReply(t *testing.T) {
	h := newHarness(t, Operations{PurposeSession: {
		"dictation_start": func(ctx context.Context, c *Conn, m Message) (Operation, error) {
			return &quickOp{conn: c, op: m.(DictationStart).Op, done: make(chan struct{})}, nil
		},
	}})
	audited := 0
	h.listener.cfg.Audit = func(accounts.AuditEntry) { audited++ }
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	// The frames are pipelined so the next start is already buffered when
	// the operation ends: the tightest form of the race.
	const ops = 200
	for op := int64(1); op <= ops; op++ {
		c.send(startMessage(op))
		c.send(DictationEnd{Op: op, TotalSamples: 0})
	}
	for op := int64(1); op <= ops; op++ {
		if m, ok := c.recv().(DictationComplete); !ok || m.Op != op {
			t.Fatalf("op %d: %#v", op, m)
		}
	}
	if audited != 0 {
		t.Fatalf("%d audit rows", audited)
	}
}

// FR-028 (Feature 018 T084): analysis, analysis_part, live_window,
// meeting_job and meeting_cancel naming another user's op are refused with
// invalid_message and a cross_user_attempt row, and return none of that
// user's data; the other user's operations run on untouched.
func TestIsolationFeature018Ops(t *testing.T) {
	x := newIsolationHarness(t)

	// Bob holds an analysis (op 2), a live window (op 3) and a meeting job
	// (op 4) open, each half received, on his three channels.
	body := analysisRequest(t, 2, nil)
	cut := len(body) / 2
	for body[cut]&0xc0 == 0x80 {
		cut--
	}
	bobAnalysis, _ := x.hello(PurposeSession, x.tokenB)
	bobAnalysis.send(AnalysisPart{Op: 2, Index: 0, Data: string(body[:cut])})
	bobLive, _ := x.hello(PurposeSession, x.tokenB)
	bobLive.send(LiveWindow{Op: 3, SampleCount: 4, Format: SampleFormat})
	bobLive.sendS16(-200, 2, 2)
	bobMeeting, _ := x.hello(PurposeSession, x.tokenB)
	bobMeeting.send(MeetingJob{Op: 4, Kind: "transcribe", SampleCount: 4, Format: SampleFormat})
	bobMeeting.sendS16(-300, 2, 2)

	sum := hexSHA256([]byte("x"))
	foreignClose := control(t, Analysis{Op: 2, Parts: 1, Bytes: 1, SHA256: sum})
	foreignPart := control(t, AnalysisPart{Op: 2, Index: 1, Data: "x"})
	aliceAnalysis := control(t, AnalysisPart{Op: 1, Index: 0, Data: "{"})
	aliceLive := control(t, LiveWindow{Op: 1, SampleCount: 4, Format: SampleFormat})
	aliceMeeting := control(t, MeetingJob{Op: 1, Kind: "transcribe", SampleCount: 4, Format: SampleFormat})
	samples := Frame{KindSamples, []byte{1, 0}}

	// On alice's idle channel: messages that continue or end an op.
	x.expectRefused("analysis with bob's op", 0, CodeInvalidMessage, true, foreignClose)
	x.expectRefused("analysis_part fragment 1 with bob's op", 0, CodeInvalidMessage, true, foreignPart)
	x.expectRefused("meeting_cancel with bob's op", 0, CodeInvalidMessage, true, control(t, MeetingCancel{Op: 4}))
	// During alice's own operations.
	x.expectRefused("analysis_part with bob's op during alice's analysis", 1, CodeInvalidMessage, true, aliceAnalysis, foreignPart)
	x.expectRefused("analysis with bob's op during alice's analysis", 1, CodeInvalidMessage, true, aliceAnalysis, foreignClose)
	x.expectRefused("live_window with bob's op during alice's live window", 1, CodeInvalidMessage, true,
		aliceLive, control(t, LiveWindow{Op: 3, SampleCount: 4, Format: SampleFormat}))
	x.expectRefused("meeting_cancel with bob's op during alice's meeting job", 1, CodeInvalidMessage, true,
		aliceMeeting, control(t, MeetingCancel{Op: 4}))
	x.expectRefused("meeting_job with bob's op during alice's meeting job", 1, CodeInvalidMessage, true,
		aliceMeeting, control(t, MeetingJob{Op: 4, Kind: "transcribe", SampleCount: 4, Format: SampleFormat}))
	x.expectRefused("meeting_cancel with a stale op", 0, CodeInvalidMessage, true,
		aliceMeeting, control(t, MeetingCancel{Op: 1}), control(t, MeetingCancel{Op: 1}))
	// Samples outside a collecting operation of alice's own carry no op.
	x.expectRefused("samples with no operation", 0, CodeInvalidMessage, false, samples)
	x.expectRefused("samples during alice's analysis", 1, CodeInvalidMessage, false, aliceAnalysis, samples)

	// Nothing of alice's reached the fakes.
	select {
	case c := <-x.live.calls:
		t.Fatalf("live window of user %d ran", c.user)
	default:
	}
	x.meeting.none(t)

	// Bob's operations complete with his own data.
	bobAnalysis.send(AnalysisPart{Op: 2, Index: 1, Data: string(body[cut:])})
	bobAnalysis.send(Analysis{Op: 2, Parts: 2, Bytes: len(body), SHA256: hexSHA256(body)})
	if req := <-x.analysis.seen; req.RequestID != analysisUUID(0x100) {
		t.Fatalf("analysis %s", req.RequestID)
	}
	close(x.analysis.hold)
	if events, _ := bobAnalysis.analysisEvents(2); len(events) != 1 {
		t.Fatalf("%d events", len(events))
	}
	bobLive.sendS16(-198, 2, 2)
	call := x.live.next(t)
	if call.user != x.userB.ID || call.samples[0] != -200.0/32768 {
		t.Fatalf("live window of user %d, first sample %v", call.user, call.samples[0])
	}
	call.answer(liveWindowJSON(4, "BobLive"), nil)
	if m, ok := x.recv("bob", bobLive).(LiveResult); !ok || m.Window.Text != "BobLive" {
		t.Fatalf("%#v", m)
	}
	bobMeeting.sendS16(-298, 2, 2)
	expectProgress(t, x.recv("bob", bobMeeting), 4, "running")
	job := x.meeting.next(t)
	if len(job.job.Samples) != 8 || int16(binary.LittleEndian.Uint16(job.job.Samples)) != -300 {
		t.Fatalf("meeting job samples %v", job.job.Samples)
	}
	job.reply <- meetingAnswer{result: transcribeResult}
	if m, ok := x.recv("bob", bobMeeting).(MeetingResult); !ok || m.Op != 4 {
		t.Fatalf("%#v", m)
	}
	if x.crossUserRows()[accounts.DeviceActor(x.deviceB.ID)] != 0 {
		t.Fatal("bob's channels were audited")
	}
	x.mu.Lock()
	defer x.mu.Unlock()
	for _, message := range x.received["alice"] {
		for _, marker := range []string{"BobLive", "Secret words", "analysis_event", "meeting_result", "live_result"} {
			if strings.Contains(message, marker) {
				t.Fatalf("alice received %q: %s", marker, message)
			}
		}
	}
}
