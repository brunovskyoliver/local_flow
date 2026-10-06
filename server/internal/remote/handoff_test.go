package remote

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"localflow/server/internal/accounts"
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
	if len(*list.Meetings) != 1 || (*list.Meetings)[0] != (HandoffMeeting{Meeting: handoffMeeting, State: "done", Mine: true}) {
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
		r, _ := s.handle(1, 1, Handoff{Action: "list"})
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
	r, _ := s.handle(1, 1, Handoff{Action: "list"})
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
	r, _ = s.handle(1, 1, Handoff{Action: "list"})
	if m := (*r.Meetings)[0]; m.Progress != nil {
		t.Fatalf("done meeting lists progress: %+v", m)
	}
}

// Feature 020: a partial run starts only from receiving, runs the processor
// with --partial and returns the meeting to receiving with the transcribed_ms
// it wrote, or with partial_failed; puts write nothing while it is queued or
// processing; rows.sqlite is replaced by a put at offset 0; a final start
// afterwards runs without --partial.
func TestHandoffPartial(t *testing.T) {
	h, s := newHandoffHarness(t, fakeProcessor(t, `
printf '%s ' "$@" > "$2/args"
case "$*" in *--partial*)
  while [ ! -f "$2/finish" ]; do sleep 0.01; done
  rm "$2/finish"
  if [ -f "$2/fail" ]; then rm "$2/fail"; exit 9; fi
  echo 360000 > "$2/transcribed_ms";;
esac`))
	user, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)
	op := int64(0)
	send := func(m Handoff) Message { op++; m.Op = op; return c.handoff(m) }
	put := func(name string, at int64, data []byte) Message {
		return send(Handoff{Action: "put", Meeting: handoffMeeting, Name: name, Offset: offset(at), Data: data, SHA256: hexSum(data)})
	}
	dir := filepath.Join(s.userDir(user.ID), handoffMeeting)
	listed := func() HandoffMeeting {
		t.Helper()
		list := expectHandoff(t, send(Handoff{Action: "list"}), "")
		if len(*list.Meetings) != 1 {
			t.Fatalf("%+v", list.Meetings)
		}
		return (*list.Meetings)[0]
	}
	finish := func() {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, "finish"), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	expectHandoff(t, send(Handoff{Action: "start", Meeting: handoffMeeting, Partial: true}), "missing")
	expectHandoff(t, put("bundle.sqlite", 0, []byte("bundle")), "receiving")
	expectCode(t, send(Handoff{Action: "start", Meeting: handoffMeeting, Partial: true}), CodeInvalidMessage)
	expectHandoff(t, put("mic-0001.aac", 0, []byte("aac1")), "receiving")
	rows := []byte("rows-version-one")
	expectHandoff(t, put("rows.sqlite", 0, rows), "receiving")
	if r := expectHandoff(t, put("rows.sqlite", 0, []byte("rows-2")), "receiving"); *r.Offset != 6 {
		t.Fatalf("rows.sqlite not replaced: %+v", r)
	}
	if got, _ := os.ReadFile(filepath.Join(dir, "rows.sqlite")); string(got) != "rows-2" {
		t.Fatalf("rows.sqlite %q", got)
	}
	// A cached hash from an earlier done state goes when the meeting is queued again.
	s.hashes[filepath.Join(dir, "bundle.sqlite")] = "stale"
	expectHandoff(t, send(Handoff{Action: "start", Meeting: handoffMeeting, Partial: true}), "queued")
	if _, ok := s.hashes[filepath.Join(dir, "bundle.sqlite")]; ok {
		t.Fatal("cached hash kept")
	}
	expectHandoff(t, send(Handoff{Action: "start", Meeting: handoffMeeting, Partial: true}), "queued")
	expectHandoff(t, put("mic-0002.aac", 0, []byte("aac2")), "queued")
	expectHandoff(t, put("rows.sqlite", 0, []byte("x")), "queued")

	runHandoffs(t, s)
	waitState(t, s, user.ID, handoffMeeting, "processing")
	expectHandoff(t, put("mic-0002.aac", 0, []byte("aac2")), "processing")
	if got, _ := os.ReadFile(filepath.Join(dir, "rows.sqlite")); string(got) != "rows-2" {
		t.Fatalf("put while processing wrote: %q", got)
	}
	if _, err := os.Stat(filepath.Join(dir, handoffMeeting, "mic-0002.aac")); err == nil {
		t.Fatal("put while processing was written")
	}
	finish()
	if detail := waitState(t, s, user.ID, handoffMeeting, "receiving"); detail != "" {
		t.Fatal(detail)
	}
	if args, _ := os.ReadFile(filepath.Join(dir, "args")); !strings.HasSuffix(string(args), "--models /m --partial ") {
		t.Fatalf("args %q", args)
	}
	if m := listed(); m.State != "receiving" || m.TranscribedMS == nil || *m.TranscribedMS != 360000 {
		t.Fatalf("%+v", m)
	}

	// A failed partial run: back to receiving with partial_failed, uploads go on.
	expectHandoff(t, put("mic-0002.aac", 0, []byte("aac2")), "receiving")
	if err := os.WriteFile(filepath.Join(dir, "fail"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	expectHandoff(t, send(Handoff{Action: "start", Meeting: handoffMeeting, Partial: true}), "queued")
	waitState(t, s, user.ID, handoffMeeting, "processing")
	finish()
	if detail := waitState(t, s, user.ID, handoffMeeting, "receiving"); detail != "partial_failed" {
		t.Fatal(detail)
	}
	if m := listed(); m.Detail != "partial_failed" || *m.TranscribedMS != 360000 {
		t.Fatalf("%+v", m)
	}
	if !strings.Contains(h.logs.String(), "state=receiving partial=true") {
		t.Fatal(h.logs.String())
	}

	// The final start runs the processor without --partial.
	expectHandoff(t, send(Handoff{Action: "start", Meeting: handoffMeeting}), "queued")
	waitState(t, s, user.ID, handoffMeeting, "done")
	if args, _ := os.ReadFile(filepath.Join(dir, "args")); strings.Contains(string(args), "--partial") {
		t.Fatalf("args %q", args)
	}
	if _, err := os.Stat(filepath.Join(dir, "partial")); err == nil {
		t.Fatal("partial marker kept")
	}
	if m := listed(); m.TranscribedMS != nil {
		t.Fatalf("done lists transcribed_ms: %+v", m)
	}
}

// A partial run left processing by a stopped flowd runs as a partial run again.
func TestHandoffPartialRequeue(t *testing.T) {
	s := NewHandoffs(HandoffConfig{Dir: t.TempDir(), Processor: fakeProcessor(t, `printf '%s ' "$@" > "$2/args"`)})
	dir := queue(t, s, handoffMeeting, "processing")
	if err := os.WriteFile(filepath.Join(dir, "partial"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	s.hashes[filepath.Join(dir, "bundle.sqlite")] = "stale"
	runHandoffs(t, s)
	waitState(t, s, 1, handoffMeeting, "receiving")
	if args, _ := os.ReadFile(filepath.Join(dir, "args")); !strings.HasSuffix(string(args), "--partial ") {
		t.Fatalf("args %q", args)
	}
	s.mu.Lock()
	_, ok := s.hashes[filepath.Join(dir, "bundle.sqlite")]
	s.mu.Unlock()
	if ok {
		t.Fatal("cached hash kept on requeue")
	}
}

// anotherDevice approves a second device for user and returns its token.
func (h *harness) anotherDevice(user accounts.User, key byte) string {
	h.t.Helper()
	ctx := context.Background()
	public := bytes.Repeat([]byte{key}, 65)
	public[0] = 0x04
	device, err := h.store.AddDevice(ctx, user.ID, "iPhone", public)
	if err != nil {
		h.t.Fatal(err)
	}
	_ = h.store.SetDeviceState(ctx, device.ID, accounts.DeviceApproved, accounts.AdminActor("test"))
	token, _, err := h.store.IssueAccess(ctx, device.ID)
	if err != nil {
		h.t.Fatal(err)
	}
	h.poll()
	return token
}

// Feature 020 Mac copy: the first put records the device, list reports mine
// per caller, copy on put or start marks the meeting, release keeps a copy
// meeting (released) and deletes one without, get with a name serves an AAC
// file, and another user still sees nothing.
func TestHandoffMacCopy(t *testing.T) {
	h, s := newHandoffHarness(t, fakeProcessor(t, `printf processed >> "$2/bundle.sqlite"`))
	user, _, phoneToken := h.approved("sub", 1)
	macToken := h.anotherDevice(user, 2)
	_, _, strangerToken := h.approved("stranger", 3)
	phone, _ := h.hello(PurposeSession, phoneToken)
	mac, _ := h.hello(PurposeSession, macToken)
	stranger, _ := h.hello(PurposeSession, strangerToken)
	op := int64(0)
	send := func(c *testClient, m Handoff) Message { op++; m.Op = op; return c.handoff(m) }
	audio := []byte("aac-audio-bytes")
	upload := func(meeting string, withCopy bool) {
		t.Helper()
		expectHandoff(t, send(phone, Handoff{Action: "put", Meeting: meeting, Name: "bundle.sqlite", Offset: offset(0), Data: []byte("b"), SHA256: hexSum([]byte("b")), Copy: withCopy}), "receiving")
		expectHandoff(t, send(phone, Handoff{Action: "put", Meeting: meeting, Name: "mic-0001.aac", Offset: offset(0), Data: audio, SHA256: hexSum(audio)}), "receiving")
	}
	entry := func(c *testClient, meeting string) (HandoffMeeting, bool) {
		t.Helper()
		list := expectHandoff(t, send(c, Handoff{Action: "list"}), "")
		for _, m := range *list.Meetings {
			if m.Meeting == meeting {
				return m, true
			}
		}
		return HandoffMeeting{}, false
	}
	runHandoffs(t, s)

	// With copy: put marks it, mine is per caller.
	upload(handoffMeeting, true)
	expectHandoff(t, send(phone, Handoff{Action: "release", Meeting: handoffMeeting}), "receiving")
	expectHandoff(t, send(phone, Handoff{Action: "start", Meeting: handoffMeeting}), "queued")
	waitState(t, s, user.ID, handoffMeeting, "done")
	if m, _ := entry(phone, handoffMeeting); !m.Mine || !m.Copy || m.Released {
		t.Fatalf("phone sees %+v", m)
	}
	if m, _ := entry(mac, handoffMeeting); m.Mine || !m.Copy || m.Released {
		t.Fatalf("mac sees %+v", m)
	}
	// get by name: an AAC file, same chunking and sha256 as the bundle.
	r := expectHandoff(t, send(mac, Handoff{Action: "get", Meeting: handoffMeeting, Name: "mic-0001.aac", Offset: offset(4)}), "done")
	if !bytes.Equal(r.Data, audio[4:]) || *r.Size != int64(len(audio)) || r.SHA256 != hexSum(audio) || r.Name != "mic-0001.aac" {
		t.Fatalf("%+v", r)
	}
	expectCode(t, send(mac, Handoff{Action: "get", Meeting: handoffMeeting, Name: "mic-0009.aac", Offset: offset(0)}), CodeInvalidMessage)
	if r := expectHandoff(t, send(mac, Handoff{Action: "get", Meeting: handoffMeeting, Offset: offset(0)}), "done"); r.SHA256 != hexSum([]byte("bprocessed")) || r.Name != "" {
		t.Fatalf("bundle %+v", r)
	}

	// release keeps it and marks it released.
	expectHandoff(t, send(phone, Handoff{Action: "release", Meeting: handoffMeeting}), "done")
	if m, ok := entry(mac, handoffMeeting); !ok || !m.Released || m.Mine {
		t.Fatalf("mac sees %+v", m)
	}
	// Another user sees and touches nothing.
	if _, ok := entry(stranger, handoffMeeting); ok {
		t.Fatal("other user's meeting listed")
	}
	expectHandoff(t, send(stranger, Handoff{Action: "get", Meeting: handoffMeeting, Name: "mic-0001.aac", Offset: offset(0)}), "missing")
	expectHandoff(t, send(stranger, Handoff{Action: "release", Meeting: handoffMeeting}), "missing")
	// The Mac deletes it after its import.
	expectHandoff(t, send(mac, Handoff{Action: "delete", Meeting: handoffMeeting}), "missing")
	if _, ok := entry(phone, handoffMeeting); ok {
		t.Fatal("imported meeting kept")
	}

	// Copy on start; without copy, release deletes like delete.
	upload(otherMeeting, false)
	expectHandoff(t, send(phone, Handoff{Action: "start", Meeting: otherMeeting}), "queued")
	waitState(t, s, user.ID, otherMeeting, "done")
	if m, _ := entry(phone, otherMeeting); m.Copy {
		t.Fatalf("%+v", m)
	}
	expectHandoff(t, send(phone, Handoff{Action: "release", Meeting: otherMeeting}), "missing")
	if _, err := os.Stat(filepath.Join(s.userDir(user.ID), otherMeeting)); !os.IsNotExist(err) {
		t.Fatal("release without copy kept the meeting")
	}
	upload(otherMeeting, false)
	expectHandoff(t, send(phone, Handoff{Action: "start", Meeting: otherMeeting, Copy: true}), "queued")
	waitState(t, s, user.ID, otherMeeting, "done")
	if m, _ := entry(phone, otherMeeting); !m.Copy || !m.Mine {
		t.Fatalf("%+v", m)
	}
	expectHandoff(t, send(phone, Handoff{Action: "release", Meeting: otherMeeting}), "done")
}

// newWatchHarness registers handoff and handoff_watch on the harness clock.
func newWatchHarness(t *testing.T) (*harness, *Handoffs) {
	t.Helper()
	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	s := NewHandoffs(HandoffConfig{Dir: t.TempDir(), Processor: fakeProcessor(t, "exit 0"), Clock: h.clock, Logger: h.listener.cfg.Logger})
	operations[PurposeSession]["handoff"] = s.Start
	operations[PurposeSession]["handoff_watch"] = s.Watch
	return h, s
}

// doneMeeting writes a processed meeting of user, first put by device.
func doneMeeting(t *testing.T, s *Handoffs, user, device int64, meeting string, copy, released bool) {
	t.Helper()
	dir := filepath.Join(s.userDir(user), meeting)
	if err := os.MkdirAll(filepath.Join(dir, meeting), 0o700); err != nil {
		t.Fatal(err)
	}
	if writeState(dir, "done", "") != nil || os.WriteFile(filepath.Join(dir, "device"), []byte(strconv.FormatInt(device, 10)), 0o600) != nil {
		t.Fatal("meeting not written")
	}
	for name, on := range map[string]bool{"copy": copy, "released": released} {
		if on && touch(filepath.Join(dir, name)) != nil {
			t.Fatal(name)
		}
	}
}

// recvAsync reads the next message in the background, so pings are answered
// while the test waits.
func (c *testClient) recvAsync() <-chan Message {
	out := make(chan Message, 1)
	go func() {
		m, err := c.tryRecv()
		if err != nil {
			m = nil
		}
		out <- m
	}()
	return out
}

func expectWatched(t *testing.T, m Message, want ...string) {
	t.Helper()
	r := expectHandoff(t, m, "")
	got := []string{}
	for _, entry := range *r.Meetings {
		if !isImportable(entry) {
			t.Fatalf("not importable: %+v", entry)
		}
		got = append(got, entry.Meeting)
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("watch named %v, want %v", got, want)
	}
}

func quiet(t *testing.T, pending <-chan Message) {
	t.Helper()
	select {
	case m := <-pending:
		t.Fatalf("watch answered early: %#v", m)
	case <-time.After(100 * time.Millisecond):
	}
}

// Feature 020: ready names handoff_watch; a watch answers at once when a
// meeting waits for the caller, and only with those meetings.
func TestHandoffWatchImmediate(t *testing.T) {
	h, s := newWatchHarness(t)
	user, mac, macToken := h.approved("sub", 1)
	c, ready := h.hello(PurposeSession, macToken)
	if r, ok := ready.(Ready); !ok || !slices.Contains(r.Capabilities.Ops, "handoff_watch") {
		t.Fatalf("%#v", ready)
	}
	doneMeeting(t, s, user.ID, mac.ID+1, handoffMeeting, true, true)
	doneMeeting(t, s, user.ID, mac.ID+1, otherMeeting, true, false) // not released yet
	expectWatched(t, c.handoff(Handoff{Op: 1, Action: "watch"}), handoffMeeting)
	// The channel takes the next op once the watch has answered.
	expectWatched(t, c.handoff(Handoff{Op: 2, Action: "watch"}), handoffMeeting)
	if !strings.Contains(h.logs.String(), "action=watch meetings=1 code=ok") {
		t.Fatal(h.logs.String())
	}
}

// A watch waits through the idle timeout and wakes when the phone releases a
// copy meeting; the Mac's own meetings, meetings without a copy and another
// user's releases do not wake it.
func TestHandoffWatchWakesOnRelease(t *testing.T) {
	h, s := newWatchHarness(t)
	user, mac, macToken := h.approved("sub", 1)
	phoneToken := h.anotherDevice(user, 2)
	stranger, strangerDevice, strangerToken := h.approved("stranger", 3)
	watcher, _ := h.hello(PurposeSession, macToken)

	watcher.send(Handoff{Op: 1, Action: "watch"})
	pending := watcher.recvAsync()
	h.clock.waitTimer(t, HandoffWatchTimeout)
	h.clock.Advance(IdleTimeout + time.Second)
	quiet(t, pending)

	// Opened after the idle timeout, which closes channels without an op.
	phone, _ := h.hello(PurposeSession, phoneToken)
	other, _ := h.hello(PurposeSession, strangerToken)
	macChannel, _ := h.hello(PurposeSession, macToken)

	// The Mac releases its own copy meeting.
	doneMeeting(t, s, user.ID, mac.ID, handoffMeeting, true, false)
	expectHandoff(t, macChannel.handoff(Handoff{Op: 1, Action: "release", Meeting: handoffMeeting}), "done")
	// Another user's phone releases a copy meeting.
	doneMeeting(t, s, stranger.ID, strangerDevice.ID+1, otherMeeting, true, false)
	expectHandoff(t, other.handoff(Handoff{Op: 1, Action: "release", Meeting: otherMeeting}), "done")
	// The phone releases a meeting without a copy: it is deleted.
	doneMeeting(t, s, user.ID, mac.ID+1, otherMeeting, false, false)
	expectHandoff(t, phone.handoff(Handoff{Op: 1, Action: "release", Meeting: otherMeeting}), "missing")
	quiet(t, pending)

	// The phone releases a copy meeting.
	doneMeeting(t, s, user.ID, mac.ID+1, otherMeeting, true, false)
	expectHandoff(t, phone.handoff(Handoff{Op: 2, Action: "release", Meeting: otherMeeting}), "done")
	select {
	case m := <-pending:
		expectWatched(t, m, otherMeeting)
	case <-time.After(5 * time.Second):
		t.Fatal("watch not woken by the release")
	}
}

// A processor run that ends with a released copy meeting done wakes a watch.
func TestHandoffWatchWakesOnProcessing(t *testing.T) {
	h, s := newWatchHarness(t)
	user, mac, macToken := h.approved("sub", 1)
	watcher, _ := h.hello(PurposeSession, macToken)
	watcher.send(Handoff{Op: 1, Action: "watch"})
	pending := watcher.recvAsync()
	quiet(t, pending)
	doneMeeting(t, s, user.ID, mac.ID+1, handoffMeeting, true, true)
	if writeState(filepath.Join(s.userDir(user.ID), handoffMeeting), "queued", "") != nil {
		t.Fatal("state")
	}
	runHandoffs(t, s)
	select {
	case m := <-pending:
		expectWatched(t, m, handoffMeeting)
	case <-time.After(5 * time.Second):
		t.Fatal("watch not woken by the processor")
	}
}

// After WatchTimeout a watch answers an empty list and the channel serves the
// next op; a meeting without a watch to wake leaves nothing behind.
func TestHandoffWatchTimeout(t *testing.T) {
	h, _ := newWatchHarness(t)
	_, _, macToken := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, macToken)
	c.send(Handoff{Op: 1, Action: "watch"})
	pending := c.recvAsync()
	h.clock.waitTimer(t, HandoffWatchTimeout)
	h.clock.Advance(HandoffWatchTimeout - time.Second)
	quiet(t, pending)
	h.clock.Advance(time.Second)
	select {
	case m := <-pending:
		expectWatched(t, m)
	case <-time.After(5 * time.Second):
		t.Fatal("no answer at the watch timeout")
	}
	expectWatched(t, c.handoff(Handoff{Op: 2, Action: "list"}))
	if !strings.Contains(h.logs.String(), "action=watch meetings=0 code=ok") {
		t.Fatal(h.logs.String())
	}
}

// Closing the channel ends a waiting watch: its goroutine returns and the
// channel's slot is freed. A watch on a server without handoff_watch is
// not_offered, and a second op on a watching channel closes it.
func TestHandoffWatchClose(t *testing.T) {
	h, _ := newWatchHarness(t)
	_, _, macToken := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, macToken)
	c.send(Handoff{Op: 1, Action: "watch"})
	quiet(t, c.recvAsync())
	before := h.listener.Registry().Len()
	c.ws.CloseNow()
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(h.logs.String(), "action=watch meetings=0 code=closed") && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !strings.Contains(h.logs.String(), "action=watch meetings=0 code=closed") {
		t.Fatal("watch still waiting after close: " + h.logs.String())
	}
	for h.listener.Registry().Len() >= before && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if h.listener.Registry().Len() >= before {
		t.Fatal("channel kept")
	}

	second, _ := h.hello(PurposeSession, macToken)
	second.send(Handoff{Op: 1, Action: "watch"})
	second.send(Handoff{Op: 2, Action: "list"})
	expectCode(t, second.recv(), CodeInvalidMessage)

	old, _ := newHandoffHarness(t, fakeProcessor(t, "exit 0"))
	_, _, oldToken := old.approved("sub", 1)
	third, ready := old.hello(PurposeSession, oldToken)
	if slices.Contains(ready.(Ready).Capabilities.Ops, "handoff_watch") {
		t.Fatal("handoff_watch offered without the op")
	}
	expectCode(t, third.handoff(Handoff{Op: 1, Action: "watch"}), CodeNotOffered)
}
