package remote

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"localflow/server/internal/speech"
)

const (
	handoffMeeting = "5F1C3A2E-9B4D-4E21-8A7C-0D6B2F8E1A93"
	otherMeeting   = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
)

// fakeProcessor writes an executable shell script running body.
func fakeProcessor(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "flowd-meeting")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func newHandoffHarness(t *testing.T, processor string) (*harness, *Handoffs) {
	t.Helper()
	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	s := NewHandoffs(HandoffConfig{Dir: t.TempDir(), Processor: processor, Args: []string{"--models", "/m"}, Logger: h.listener.cfg.Logger})
	operations[PurposeSession]["handoff"] = s.Start
	return h, s
}

func offset(n int64) *int64 { return &n }

func hexSum(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func (c *testClient) handoff(m Handoff) Message {
	c.t.Helper()
	c.send(m)
	return c.recv()
}

func expectHandoff(t *testing.T, m Message, state string) HandoffReply {
	t.Helper()
	r, ok := m.(HandoffReply)
	if !ok || r.State != state {
		t.Fatalf("got %#v, want handoff_reply %s", m, state)
	}
	return r
}

func expectCode(t *testing.T, m Message, code ErrorCode) {
	t.Helper()
	if e, ok := m.(ErrorMessage); !ok || e.Code != code {
		t.Fatalf("got %#v, want error %s", m, code)
	}
}

func waitState(t *testing.T, s *Handoffs, user int64, meeting, state string) (detail string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		got, detail := readState(filepath.Join(s.userDir(user), meeting))
		if got == state {
			return detail
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("meeting never reached %s", state)
	return ""
}

func runHandoffs(t *testing.T, s *Handoffs) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	stopped := make(chan struct{})
	go func() { s.Run(ctx); close(stopped) }()
	t.Cleanup(func() { cancel(); <-stopped })
}

// An upload resumes from the stored size, a chunk at another offset writes
// nothing, a wrong sha256 empties the file, start needs the bundle and audio,
// the processor's bundle is read back in chunks with its sha256, and delete
// removes everything.
func TestHandoffRoundTrip(t *testing.T) {
	h, s := newHandoffHarness(t, fakeProcessor(t, `printf '%s ' "$@" > "$2/args"; printf processed >> "$2/bundle.sqlite"`))
	user, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)
	op := int64(0)
	send := func(m Handoff) Message { op++; m.Op = op; return c.handoff(m) }
	put := func(name string, at int64, data []byte, sum string) HandoffReply {
		return expectHandoff(t, send(Handoff{Action: "put", Meeting: handoffMeeting, Name: name, Offset: offset(at), Data: data, SHA256: sum}), "receiving")
	}

	expectHandoff(t, send(Handoff{Action: "start", Meeting: handoffMeeting}), "missing")
	bundle := []byte("sqlite-bundle")
	if r := put("bundle.sqlite", 0, bundle[:6], ""); *r.Offset != 6 || r.Name != "bundle.sqlite" || r.Meeting != handoffMeeting {
		t.Fatalf("%+v", r)
	}
	if r := put("bundle.sqlite", 0, bundle[:6], ""); *r.Offset != 6 {
		t.Fatalf("resent chunk written: %d", *r.Offset)
	}
	if r := put("bundle.sqlite", 6, bundle[6:], hexSum([]byte("other"))); *r.Offset != 0 {
		t.Fatalf("mismatch kept: %d", *r.Offset)
	}
	if r := put("bundle.sqlite", 0, bundle, hexSum(bundle)); *r.Offset != int64(len(bundle)) {
		t.Fatalf("%+v", r)
	}
	expectCode(t, send(Handoff{Action: "start", Meeting: handoffMeeting}), CodeInvalidMessage)
	audio := []byte("aac")
	put("mic-0001.aac", 0, audio, hexSum(audio))
	if r := put("mic-0000.aac", 0, nil, hexSum(nil)); *r.Offset != 0 {
		t.Fatalf("empty file: %+v", r)
	}
	dir := filepath.Join(s.userDir(user.ID), handoffMeeting)
	if got, _ := os.ReadFile(filepath.Join(dir, handoffMeeting, "mic-0001.aac")); !bytes.Equal(got, audio) {
		t.Fatal("audio not stored under <UUID>/")
	}
	expectHandoff(t, send(Handoff{Action: "start", Meeting: handoffMeeting}), "queued")
	expectHandoff(t, send(Handoff{Action: "put", Meeting: handoffMeeting, Name: "mic-0002.aac", Offset: offset(0), Data: audio}), "queued")
	expectHandoff(t, send(Handoff{Action: "get", Meeting: handoffMeeting, Offset: offset(0)}), "queued")

	runHandoffs(t, s)
	waitState(t, s, user.ID, handoffMeeting, "done")
	if _, err := os.Stat(filepath.Join(dir, handoffMeeting, "mic-0002.aac")); err == nil {
		t.Fatal("put after start was written")
	}
	args, _ := os.ReadFile(filepath.Join(dir, "args"))
	if want := "--bundle " + dir + " --meeting " + handoffMeeting + " --models /m "; string(args) != want {
		t.Fatalf("args %q", args)
	}
	want := append(bundle, "processed"...)
	r := expectHandoff(t, send(Handoff{Action: "get", Meeting: handoffMeeting, Offset: offset(4)}), "done")
	if !bytes.Equal(r.Data, want[4:]) || *r.Size != int64(len(want)) || r.SHA256 != hexSum(want) || *r.Offset != 4 {
		t.Fatalf("%+v", r)
	}
	if r := expectHandoff(t, send(Handoff{Action: "get", Meeting: handoffMeeting, Offset: offset(int64(len(want)))}), "done"); r.Data != nil {
		t.Fatal("data at the end")
	}
	expectCode(t, send(Handoff{Action: "get", Meeting: handoffMeeting, Offset: offset(100)}), CodeInvalidMessage)
	list := expectHandoff(t, send(Handoff{Action: "list"}), "")
	if len(*list.Meetings) != 1 || (*list.Meetings)[0] != (HandoffMeeting{Meeting: handoffMeeting, State: "done"}) {
		t.Fatalf("%+v", list.Meetings)
	}
	expectHandoff(t, send(Handoff{Action: "delete", Meeting: handoffMeeting}), "missing")
	expectHandoff(t, send(Handoff{Action: "delete", Meeting: handoffMeeting}), "missing")
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatal("meeting dir kept")
	}
	if list := expectHandoff(t, send(Handoff{Action: "list"}), ""); len(*list.Meetings) != 0 {
		t.Fatal("deleted meeting listed")
	}
	if strings.Contains(h.logs.String(), "processed") || !strings.Contains(h.logs.String(), "remote handoff meeting=5F1C3A2E state=done") {
		t.Fatal(h.logs.String())
	}
}

// One user never sees or touches another's meetings; a user holds at most
// MaxHandoffMeetings.
func TestHandoffIsolationAndLimit(t *testing.T) {
	h, s := newHandoffHarness(t, fakeProcessor(t, "exit 0"))
	_, _, tokenA := h.approved("a", 1)
	userB, _, tokenB := h.approved("b", 2)
	a, _ := h.hello(PurposeSession, tokenA)
	b, _ := h.hello(PurposeSession, tokenB)
	expectHandoff(t, a.handoff(Handoff{Op: 1, Action: "put", Meeting: handoffMeeting, Name: "bundle.sqlite", Offset: offset(0), Data: []byte("a")}), "receiving")
	if list := expectHandoff(t, b.handoff(Handoff{Op: 1, Action: "list"}), ""); len(*list.Meetings) != 0 {
		t.Fatal("other user's meeting listed")
	}
	expectHandoff(t, b.handoff(Handoff{Op: 2, Action: "get", Meeting: handoffMeeting, Offset: offset(0)}), "missing")
	expectHandoff(t, b.handoff(Handoff{Op: 3, Action: "delete", Meeting: handoffMeeting}), "missing")
	if r := expectHandoff(t, a.handoff(Handoff{Op: 2, Action: "put", Meeting: handoffMeeting, Name: "bundle.sqlite", Offset: offset(1)}), "receiving"); *r.Offset != 1 {
		t.Fatal("other user's delete reached the meeting")
	}
	for i := range MaxHandoffMeetings {
		id := strings.Replace(otherMeeting, "0A1B", "0A"+string("0123456789ABCDEF"[i])+"B", 1)
		expectHandoff(t, b.handoff(Handoff{Op: int64(4 + i), Action: "put", Meeting: id, Name: "bundle.sqlite", Offset: offset(0)}), "receiving")
	}
	expectCode(t, b.handoff(Handoff{Op: 99, Action: "put", Meeting: handoffMeeting, Name: "bundle.sqlite", Offset: offset(0)}), CodeLimitExceeded)
	if n := len(meetings(s.userDir(userB.ID))); n != MaxHandoffMeetings {
		t.Fatal(n)
	}
}

// queue writes a complete meeting in state for user 1.
func queue(t *testing.T, s *Handoffs, meeting, state string) string {
	t.Helper()
	dir := filepath.Join(s.userDir(1), meeting)
	if err := os.MkdirAll(filepath.Join(dir, meeting), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := writeState(dir, state, ""); err != nil {
		t.Fatal(err)
	}
	return dir
}

// A non-zero exit is failed exit_<n>, an overrun is killed as failed
// timeout, a meeting left processing is requeued at start, and meeting
// dirs older than the retention are swept.
func TestHandoffRunner(t *testing.T) {
	// Only the overrun gets a short timeout: a loaded machine can take longer than
	// that just to start the shell.
	for _, tc := range []struct {
		body, state, detail string
		timeout             time.Duration
	}{{"exit 3", "failed", "exit_3", 10 * time.Second}, {"exec sleep 30", "failed", "timeout", 200 * time.Millisecond}, {"exit 0", "done", "", 10 * time.Second}} {
		s := NewHandoffs(HandoffConfig{Dir: t.TempDir(), Processor: fakeProcessor(t, tc.body), Timeout: tc.timeout})
		queue(t, s, handoffMeeting, "processing")
		runHandoffs(t, s)
		if detail := waitState(t, s, 1, handoffMeeting, tc.state); detail != tc.detail {
			t.Fatalf("%s: detail %q", tc.body, detail)
		}
		r, _ := s.handle(1, Handoff{Action: "list"})
		if (*r.Meetings)[0].Detail != tc.detail {
			t.Fatalf("%+v", r.Meetings)
		}
	}

	s := NewHandoffs(HandoffConfig{Dir: t.TempDir(), Processor: filepath.Join(t.TempDir(), "missing")})
	old := queue(t, s, otherMeeting, "done")
	stale := time.Now().Add(-HandoffRetention - time.Hour)
	if err := os.Chtimes(old, stale, stale); err != nil {
		t.Fatal(err)
	}
	queue(t, s, handoffMeeting, "queued")
	runHandoffs(t, s)
	if detail := waitState(t, s, 1, handoffMeeting, "failed"); detail != "start_failed" {
		t.Fatal(detail)
	}
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("expired meeting kept")
	}
}

// Shutdown kills a running processor and leaves its meeting processing.
func TestHandoffShutdown(t *testing.T) {
	s := NewHandoffs(HandoffConfig{Dir: t.TempDir(), Processor: fakeProcessor(t, "exec sleep 30")})
	queue(t, s, handoffMeeting, "queued")
	ctx, cancel := context.WithCancel(context.Background())
	stopped := make(chan struct{})
	go func() { s.Run(ctx); close(stopped) }()
	waitState(t, s, 1, handoffMeeting, "processing")
	time.Sleep(50 * time.Millisecond)
	cancel()
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return")
	}
	if state, _ := readState(filepath.Join(s.userDir(1), handoffMeeting)); state != "processing" {
		t.Fatal(state)
	}
}

// A processing meeting lists the processor's percent done; the processor is
// stopped while interactive work is in flight and continues after it.
func TestHandoffProgressAndPause(t *testing.T) {
	q := speech.NewMeetingQueue(nil)
	s := NewHandoffs(HandoffConfig{Dir: t.TempDir(), Interactive: q, Processor: fakeProcessor(t, `
echo 42 > "$2/progress"
i=0
while [ ! -f "$2/finish" ]; do i=$((i+1)); echo $i > "$2/ticks"; sleep 0.01; done`)})
	dir := queue(t, s, handoffMeeting, "queued")
	runHandoffs(t, s)
	waitState(t, s, 1, handoffMeeting, "processing")
	ticks := func() string { data, _ := os.ReadFile(filepath.Join(dir, "ticks")); return string(data) }
	advancing := func() bool {
		before := ticks()
		time.Sleep(150 * time.Millisecond)
		return ticks() != before
	}
	deadline := time.Now().Add(5 * time.Second)
	for ticks() == "" && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	r, _ := s.handle(1, Handoff{Action: "list"})
	if m := (*r.Meetings)[0]; m.Progress == nil || *m.Progress != 42 {
		t.Fatalf("%+v", m)
	}

	end := q.BeginInteractive()
	time.Sleep(50 * time.Millisecond)
	if advancing() {
		t.Fatal("processor ran during interactive work")
	}
	end()
	if !advancing() {
		t.Fatal("processor not continued")
	}

	if err := os.WriteFile(filepath.Join(dir, "finish"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	waitState(t, s, 1, handoffMeeting, "done")
	r, _ = s.handle(1, Handoff{Action: "list"})
	if m := (*r.Meetings)[0]; m.Progress != nil {
		t.Fatalf("done meeting lists progress: %+v", m)
	}
}
