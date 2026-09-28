package remote

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"log"
	"math/rand/v2"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"localflow/server/internal/accounts"
)

// RevocationBound is SC-007: an admin revocation closes every affected
// channel within one second.
const RevocationBound = time.Second

// revocationHarness runs the listener as flowd serve does: the system clock,
// the account watcher polling data_version every 250 ms on a real ticker and
// calling Listener.Revoke, and flowd admin as a second store connection.
type revocationHarness struct {
	*harness
	admin *accounts.Store
}

func newRevocationHarness(t *testing.T) *revocationHarness {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "data")
	store, err := accounts.Open(dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	admin, err := accounts.Open(dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { admin.Close() })
	h := &harness{t: t, store: store, logs: &lockedWriter{}}
	h.watcher, err = store.Watch(context.Background(), func(lost accounts.Lost) { h.listener.Revoke(lost) })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { h.watcher.Close() })
	h.identity, err = accounts.Keychain{Runner: &memoryKeychain{items: map[string]string{}}, Service: accounts.ServiceDevelopment}.Create(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	operations := AccountOperations(AccountsConfig{Store: store, Verifier: nil,
		Reload: func(ctx context.Context) error { _, err := h.watcher.Poll(ctx); return err }})
	operations[PurposeSession] = map[string]OperationStart{
		"dictation_start": func(ctx context.Context, c *Conn, m Message) (Operation, error) {
			start := m.(DictationStart)
			return &fakeDictation{conn: c, op: start.Op, done: make(chan struct{})}, c.Send(ctx, DictationAccepted{Op: start.Op,
				WindowSamples: WindowSamples, Model: ModelIdentity{Engine: "e", ModelID: "m", ModelRevision: "r", ManifestHash: "h", SDK: "s", WorkerBuild: "w"}})
		},
		"rewrite": func(ctx context.Context, c *Conn, m Message) (Operation, error) {
			rewrite := m.(Rewrite)
			if strings.Contains(string(rewrite.Request), "flood") {
				return newFlood(c, rewrite.Op), nil
			}
			return nil, c.Send(ctx, RewriteEvent{Op: rewrite.Op, Event: json.RawMessage(`{"event":"accepted"}`)})
		},
	}
	h.listener = NewListener(Config{Identity: h.identity, Accounts: h.watcher, ServerVersion: "0.14.0",
		Logger: log.New(h.logs, "", 0), Operations: operations})
	server := httptest.NewServer(h.listener)
	ctx, stop := context.WithCancel(context.Background())
	ticker := time.NewTicker(accounts.PollInterval)
	polling := make(chan struct{})
	go func() {
		defer close(polling)
		h.watcher.Run(ctx, ticker.C)
	}()
	t.Cleanup(func() {
		stop()
		ticker.Stop()
		<-polling
		h.listener.CloseAll()
		server.Close()
	})
	h.url = server.URL
	return &revocationHarness{harness: h, admin: admin}
}

// member is an approved device with its access and refresh tokens.
type member struct {
	user, device int64
	key          *device
	access       string
	refresh      string
}

func (h *revocationHarness) member(user int64, subject string) member {
	h.t.Helper()
	ctx := context.Background()
	admin := accounts.AdminActor("test")
	if user == 0 {
		u, _, err := h.store.EnsureUser(ctx, "apple", subject, "")
		if err != nil {
			h.t.Fatal(err)
		}
		user = u.ID
		_ = h.store.SetUserState(ctx, user, accounts.UserApproved, admin)
	}
	key := newDevice(h.t)
	row, err := h.store.AddDevice(ctx, user, "Mac", key.public)
	if err != nil {
		h.t.Fatal(err)
	}
	_ = h.store.SetDeviceState(ctx, row.ID, accounts.DeviceApproved, admin)
	refresh, _, _ := h.store.IssueRefresh(ctx, row.ID)
	access, _, _ := h.store.IssueAccess(ctx, row.ID)
	h.poll()
	return member{user: user, device: row.ID, key: key, access: access, refresh: refresh}
}

func (h *revocationHarness) session(m member) *testClient {
	h.t.Helper()
	c, first := h.hello(PurposeSession, m.access)
	if first.MessageType() != "ready" {
		h.t.Fatalf("%#v", first)
	}
	return c
}

// watchClose reads a revoked channel from now on: it reports when the
// server's close arrived and whether a sealed error{code:"revoked"} came
// first.
type closeResult struct {
	at      time.Time
	revoked bool
	op      int64
}

func watchClose(c *testClient) <-chan closeResult {
	result := make(chan closeResult, 1)
	go func() {
		var r closeResult
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for {
			_, data, err := c.ws.Read(ctx)
			if err != nil {
				r.at = time.Now()
				result <- r
				return
			}
			if frame, err := c.channel.Open(data); err == nil {
				if m, err := DecodeMessage(frame.Payload); err == nil {
					if e, ok := m.(ErrorMessage); ok && e.Code == CodeRevoked {
						r.revoked, r.op = true, e.Op
					}
				}
			}
		}
	}()
	return result
}

// stream keeps a dictation sending audio until stop is closed, so the
// channel is mid-operation when the revocation lands.
func stream(c *testClient, stop <-chan struct{}) {
	go func() {
		ticker := time.NewTicker(10 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				sealed, err := c.channel.Seal(Frame{KindAudio, make([]byte, 4*1600)})
				if err != nil || c.ws.Write(context.Background(), websocket.MessageBinary, sealed) != nil {
					return
				}
			}
		}
	}()
}

// revocationTrial revokes a device (byUser false) or a user from flowd
// admin's connection while the device has an idle and a streaming channel,
// and returns the time from the admin call to the last affected channel's
// close. Other users' channels must stay open; the revoked device's refresh
// and a revoked user's other device's hello must fail.
func revocationTrial(t *testing.T, byUser bool) time.Duration {
	t.Helper()
	h := newRevocationHarness(t)
	ctx := context.Background()
	a1 := h.member(0, "a")
	a2 := h.member(a1.user, "")
	b := h.member(0, "b")

	idle, streaming := h.session(a1), h.session(a1)
	streaming.send(DictationStart{Op: 1, Format: AudioFormat, SampleRate: SampleRate})
	if m := streaming.recv(); m.MessageType() != "dictation_accepted" {
		t.Fatalf("%#v", m)
	}
	stop := make(chan struct{})
	defer close(stop)
	stream(streaming, stop)
	sibling, other := h.session(a2), h.session(b)

	affected := []*testClient{idle, streaming}
	if byUser {
		affected = append(affected, sibling)
	}
	results := make([]<-chan closeResult, len(affected))
	for i, c := range affected {
		results[i] = watchClose(c)
	}
	// Let the stream run, and land the revocation at a random phase of the
	// 250 ms poll so the trials sample the whole interval.
	time.Sleep(20*time.Millisecond + rand.N(accounts.PollInterval))
	start := time.Now()
	var err error
	if byUser {
		err = h.admin.SetUserState(ctx, a1.user, accounts.UserRevoked, accounts.AdminActor("test"))
	} else {
		err = h.admin.SetDeviceState(ctx, a1.device, accounts.DeviceRevoked, accounts.AdminActor("test"))
	}
	if err != nil {
		t.Fatal(err)
	}
	var latest time.Duration
	for i, result := range results {
		r := <-result
		elapsed := r.at.Sub(start)
		if !r.revoked {
			t.Errorf("channel %d closed without error{code:revoked}", i)
		}
		if affected[i] == streaming && r.op != 1 {
			t.Errorf("mid-operation revoked error op %d, want 1", r.op)
		}
		latest = max(latest, elapsed)
	}
	if latest > RevocationBound {
		t.Errorf("revocation took %v, bound %v", latest, RevocationBound)
	}

	// Other users' channels stay open and usable.
	other.send(Rewrite{Op: 1, Request: json.RawMessage(`{}`)})
	if m := other.recv(); m.MessageType() != "rewrite_event" {
		t.Fatalf("other user's channel: %#v", m)
	}
	if !byUser {
		sibling.send(Rewrite{Op: 1, Request: json.RawMessage(`{}`)})
		if m := sibling.recv(); m.MessageType() != "rewrite_event" {
			t.Fatalf("same user's other device: %#v", m)
		}
	}
	// The revoked device's next refresh fails.
	c, first := h.hello(PurposeRefresh, "")
	if first.MessageType() != "ready" {
		t.Fatal(first)
	}
	hash := sha256.Sum256([]byte(a1.refresh))
	c.send(Refresh{Op: 1, RefreshToken: a1.refresh, Signature: a1.key.sign(t, []byte(RefreshSignatureLabel), c.channel.Binding(), hash[:])})
	if m, ok := c.recv().(ErrorMessage); !ok || m.Code != CodeRevoked {
		t.Fatalf("refresh after revocation: %#v", m)
	}
	// The revoked device, and after a user revocation every device of the
	// user, is refused at hello.
	_, first = h.hello(PurposeSession, a1.access)
	expectError(t, first, 0, CodeRevoked)
	if byUser {
		_, first = h.hello(PurposeSession, a2.access)
		expectError(t, first, 0, CodeRevoked)
	}
	return latest
}

// runRevocationTrials alternates device and user revocations.
func runRevocationTrials(t *testing.T, n int) []time.Duration {
	t.Helper()
	latencies := make([]time.Duration, 0, n)
	for i := range n {
		latencies = append(latencies, revocationTrial(t, i%2 == 1))
	}
	return latencies
}

// SC-007 with the real 250 ms poll: 3 trials in the normal run; 50 under
// -tags localflow_acceptance (revocation_acceptance_test.go).
func TestRevocationClosesChannelsWithinOneSecond(t *testing.T) {
	latencies := runRevocationTrials(t, 3)
	t.Logf("revocation close latencies: %v", latencies)
}

func latencySummary(latencies []time.Duration) (median, maximum time.Duration) {
	sorted := slices.Clone(latencies)
	slices.Sort(sorted)
	return sorted[len(sorted)/2], sorted[len(sorted)-1]
}

// flood is an operation that sends large events until the channel closes, so
// a client that stops reading fills the socket buffers and the operation
// blocks in Send holding the channel's send lock.
type flood struct {
	done chan struct{}
	once sync.Once
}

func newFlood(c *Conn, op int64) *flood {
	f := &flood{done: make(chan struct{})}
	event := json.RawMessage(`{"event":"` + strings.Repeat("x", 60000) + `"}`)
	go func() {
		defer f.Close()
		for c.Send(context.Background(), RewriteEvent{Op: op, Event: event}) == nil {
		}
	}()
	return f
}

func (f *flood) Control(context.Context, Message) error { return nil }
func (f *flood) Audio(context.Context, []byte) error    { return nil }
func (f *flood) Done() <-chan struct{}                  { return f.done }
func (f *flood) Close()                                 { f.once.Do(func() { close(f.done) }) }

// A channel that cannot be written (the client stopped reading while an
// operation is blocked sending) is still closed within the bound, without
// waiting for the 10 s write timeout or the close handshake.
func TestRevocationClosesUnwritableChannel(t *testing.T) {
	h := newRevocationHarness(t)
	a := h.member(0, "a")
	b := h.member(0, "b")
	stuck, other := h.session(a), h.session(b)
	stuck.send(Rewrite{Op: 1, Request: json.RawMessage(`{"flood":true}`)})
	time.Sleep(300 * time.Millisecond) // the client never reads; buffers fill
	start := time.Now()
	if err := h.admin.SetDeviceState(context.Background(), a.device, accounts.DeviceRevoked, accounts.AdminActor("test")); err != nil {
		t.Fatal(err)
	}
	for len(h.listener.Registry().Device(a.device)) != 0 {
		if time.Since(start) > RevocationBound {
			t.Fatalf("unwritable channel still open after %v", time.Since(start))
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Logf("unwritable channel closed after %v", time.Since(start))
	other.send(Rewrite{Op: 1, Request: json.RawMessage(`{}`)})
	if m := other.recv(); m.MessageType() != "rewrite_event" {
		t.Fatalf("other user's channel: %#v", m)
	}
}
