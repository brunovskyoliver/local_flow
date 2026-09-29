package remote

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"

	"localflow/server/internal/accounts"
)

// manualClock is a fake Clock: timers fire only when Advance passes them.
type manualClock struct {
	mu     sync.Mutex
	now    time.Time
	timers []*manualTimer
}

type manualTimer struct {
	clock    *manualClock
	deadline time.Time
	f        func()
	stopped  bool
}

func newManualClock() *manualClock { return &manualClock{now: time.UnixMilli(1_790_000_000_000)} }

func (c *manualClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *manualClock) AfterFunc(d time.Duration, f func()) Timer {
	c.mu.Lock()
	defer c.mu.Unlock()
	t := &manualTimer{clock: c, deadline: c.now.Add(d), f: f}
	c.timers = append(c.timers, t)
	return t
}

func (t *manualTimer) Stop() bool {
	t.clock.mu.Lock()
	defer t.clock.mu.Unlock()
	was := !t.stopped
	t.stopped = true
	return was
}

// Advance moves the clock and runs every timer that came due, in deadline
// order.
func (c *manualClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	var due, rest []*manualTimer
	for _, t := range c.timers {
		switch {
		case t.stopped:
		case !t.deadline.After(c.now):
			t.stopped = true
			due = append(due, t)
		default:
			rest = append(rest, t)
		}
	}
	c.timers = rest
	c.mu.Unlock()
	sort.Slice(due, func(i, j int) bool { return due[i].deadline.Before(due[j].deadline) })
	for _, t := range due {
		t.f()
	}
}

// pending counts live timers due within d from now.
func (c *manualClock) pending(d time.Duration) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, t := range c.timers {
		if !t.stopped && !t.deadline.After(c.now.Add(d)) {
			n++
		}
	}
	return n
}

// waitTimer waits until a timer due exactly d from now is armed.
func (c *manualClock) waitTimer(t *testing.T, d time.Duration) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		for _, timer := range c.timers {
			if !timer.stopped && timer.deadline.Equal(c.now.Add(d)) {
				c.mu.Unlock()
				return
			}
		}
		c.mu.Unlock()
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("no timer armed for %v", d)
}

// harness is a listener on an httptest server with a real account store.
type harness struct {
	t        *testing.T
	clock    *manualClock
	store    *accounts.Store
	watcher  *accounts.Watcher
	identity *accounts.Identity
	listener *Listener
	url      string
	logs     *lockedWriter
}

type memoryKeychain struct{ items map[string]string }

func (m *memoryKeychain) Run(_ context.Context, stdin []byte, args ...string) ([]byte, error) {
	key := args[2] + "|" + args[4]
	if args[0] == "add-generic-password" {
		m.items[key] = strings.SplitN(string(stdin), "\n", 2)[0]
		return nil, nil
	}
	if secret, ok := m.items[key]; ok {
		return []byte(secret), nil
	}
	return nil, exitStatus(44)
}

type exitStatus int

func (e exitStatus) Error() string { return "exit" }
func (e exitStatus) ExitCode() int { return int(e) }

func newHarness(t *testing.T, operations Operations) *harness {
	t.Helper()
	clock := newManualClock()
	dir := filepath.Join(t.TempDir(), "data")
	store, err := accounts.Open(dir, clock.Now)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	watcher, err := store.Watch(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { watcher.Close() })
	identity, err := accounts.Keychain{Runner: &memoryKeychain{items: map[string]string{}}, Service: accounts.ServiceDevelopment}.Create(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	logs := &lockedWriter{}
	listener := NewListener(Config{
		Identity: identity, Accounts: watcher, ServerVersion: "0.14.0", Clock: clock,
		Logger: log.New(logs, "", 0), Operations: operations,
	})
	server := httptest.NewServer(listener)
	t.Cleanup(func() {
		listener.CloseAll()
		server.Close()
	})
	return &harness{t, clock, store, watcher, identity, listener, server.URL, logs}
}

type lockedWriter struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.Write(p)
}

func (l *lockedWriter) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.String()
}

// approved creates an approved user and device with a live access token.
func (h *harness) approved(subject string, key byte) (accounts.User, accounts.Device, string) {
	h.t.Helper()
	ctx := context.Background()
	user, _, err := h.store.EnsureUser(ctx, "apple", subject, "")
	if err != nil {
		h.t.Fatal(err)
	}
	public := bytes.Repeat([]byte{key}, 65)
	public[0] = 0x04
	device, err := h.store.AddDevice(ctx, user.ID, "Mac", public)
	if err != nil {
		h.t.Fatal(err)
	}
	_ = h.store.SetUserState(ctx, user.ID, accounts.UserApproved, accounts.AdminActor("test"))
	_ = h.store.SetDeviceState(ctx, device.ID, accounts.DeviceApproved, accounts.AdminActor("test"))
	token, _, err := h.store.IssueAccess(ctx, device.ID)
	if err != nil {
		h.t.Fatal(err)
	}
	h.poll()
	return user, device, token
}

func (h *harness) poll() {
	h.t.Helper()
	if _, err := h.watcher.Poll(context.Background()); err != nil {
		h.t.Fatal(err)
	}
}

// testClient is the client end of one channel.
type testClient struct {
	t       *testing.T
	ws      *websocket.Conn
	channel *Channel
	pings   atomic.Int32
}

func (h *harness) dial() *testClient {
	h.t.Helper()
	return h.dialFrom("")
}

// dialFrom dials as the client cloudflared reports in Cf-Connecting-Ip (none
// when empty: the loopback peer address is the client).
func (h *harness) dialFrom(client string) *testClient {
	h.t.Helper()
	c := &testClient{t: h.t}
	ws, err := h.tryDial(client, func(context.Context, []byte) bool { c.pings.Add(1); return true })
	if err != nil {
		h.t.Fatal(err)
	}
	ws.SetReadLimit(MaxBinaryMessage)
	h.t.Cleanup(func() { ws.CloseNow() })
	c.ws = ws
	return c
}

func (h *harness) tryDial(client string, onPing func(context.Context, []byte) bool) (*websocket.Conn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	header := http.Header{}
	if client != "" {
		header.Set("Cf-Connecting-Ip", client)
	}
	ws, resp, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(h.url, "http")+"/v1/remote/channel", &websocket.DialOptions{
		HTTPHeader: header, OnPingReceived: onPing,
	})
	if err != nil && resp != nil && resp.StatusCode == http.StatusServiceUnavailable {
		return nil, errRefused
	}
	return ws, err
}

var errRefused = errors.New("upgrade refused with 503")

// hello dials and sends a hello with the given purpose (and token for
// session), returning the client and the server's first message.
func (h *harness) hello(purpose Purpose, token string) (*testClient, Message) {
	h.t.Helper()
	return h.helloFrom("", purpose, token)
}

func (h *harness) helloFrom(client string, purpose Purpose, token string) (*testClient, Message) {
	h.t.Helper()
	c := h.dialFrom(client)
	replyKey := newKey(h.t)
	channel, err := NewClient(h.identity.PublicKey(), replyKey)
	if err != nil {
		h.t.Fatal(err)
	}
	c.channel = channel
	body := map[string]any{"schema_version": 1, "type": "hello", "reply_key": b64(replyKey.PublicKey().Bytes()), "purpose": purpose}
	if token != "" {
		body["access_token"] = token
	}
	plaintext, _ := json.Marshal(body)
	sealed, _ := channel.Hello(plaintext)
	if err := c.ws.Write(context.Background(), websocket.MessageBinary, sealed); err != nil {
		h.t.Fatal(err)
	}
	return c, c.recv()
}

func (c *testClient) recv() Message {
	c.t.Helper()
	message, err := c.tryRecv()
	if err != nil {
		c.t.Fatal(err)
	}
	return message
}

func (c *testClient) tryRecv() (Message, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := c.ws.Read(ctx)
	if err != nil {
		return nil, err
	}
	frame, err := c.channel.Open(data)
	if err != nil {
		return nil, err
	}
	return DecodeMessage(frame.Payload)
}

// closed waits for the server to close and returns the close status.
func (c *testClient) closed() websocket.StatusCode {
	c.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		_, data, err := c.ws.Read(ctx)
		if err != nil {
			if ctx.Err() != nil {
				c.t.Fatal("server did not close")
			}
			return websocket.CloseStatus(err)
		}
		if _, err := c.channel.Open(data); err == nil {
			c.t.Fatal("unexpected message before close")
		}
	}
}

func (c *testClient) send(m Message) {
	c.t.Helper()
	data, err := EncodeMessage(m)
	if err != nil {
		c.t.Fatal(err)
	}
	c.sendFrame(Frame{KindControl, data})
}

func (c *testClient) sendFrame(f Frame) {
	c.t.Helper()
	sealed, err := c.channel.Seal(f)
	if err != nil {
		c.t.Fatal(err)
	}
	if err := c.ws.Write(context.Background(), websocket.MessageBinary, sealed); err != nil {
		c.t.Fatal(err)
	}
}

func expectError(t *testing.T, m Message, op int64, code ErrorCode) {
	t.Helper()
	e, ok := m.(ErrorMessage)
	if !ok || e.Code != code || e.Op != op || e.Message != code.Message() {
		t.Fatalf("got %#v, want error op %d %s", m, op, code)
	}
}

func TestListenRefusesNonLoopback(t *testing.T) {
	for _, addr := range []string{"0.0.0.0:0", "192.168.1.10:0", "localhost:0", ":0", "[::]:0", "nonsense"} {
		if l, err := Listen(addr); err == nil {
			l.Close()
			t.Errorf("%s accepted", addr)
		}
	}
	for _, addr := range []string{"127.0.0.1:0", "[::1]:0"} {
		l, err := Listen(addr)
		if err != nil {
			t.Errorf("%s: %v", addr, err)
			continue
		}
		l.Close()
	}
}

func TestIdentityEndpointAndRoutes(t *testing.T) {
	h := newHarness(t, Operations{})
	resp, err := http.Get(h.url + "/v1/remote/identity")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	identity, err := DecodeIdentity(body)
	if err != nil || resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "application/json" {
		t.Fatal(resp.StatusCode, string(body), err)
	}
	if identity.Server != "flowd/0.14.0" || len(identity.ProtocolVersions) != 1 || identity.ProtocolVersions[0] != 1 ||
		identity.Suite != "x25519-hkdfsha256-chacha20poly1305" || !bytes.Equal(identity.ServerKey, h.identity.PublicKey()) ||
		identity.Fingerprint != h.identity.Fingerprint() {
		t.Fatalf("%+v", identity)
	}
	if !strings.Contains(string(body), `"server_key":"`+b64(h.identity.PublicKey())+`"`) {
		t.Fatal("server_key must be base64url without padding")
	}
	for _, request := range []struct{ method, path string }{
		{"POST", "/v1/remote/identity"},
		{"GET", "/v1/remote/identity/extra"},
		{"GET", "/v1/remote"},
		{"GET", "/v1/rewrite/health"},
		{"GET", "/v1/analysis/health"},
		{"GET", "/"},
		{"POST", "/v1/remote/channel"},
	} {
		req, _ := http.NewRequest(request.method, h.url+request.path, nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != 404 {
			t.Errorf("%s %s: %d", request.method, request.path, resp.StatusCode)
		}
	}
}

// waitOpen waits until the listener has released closed channels.
func (h *harness) waitAnonymous(t *testing.T, n int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		h.listener.slotsMu.Lock()
		got := h.listener.anonymous
		h.listener.slotsMu.Unlock()
		if got == n {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("anonymous channels never reached %d", n)
}

// A client may hold 4 channels that no session hello has authenticated;
// the 5th upgrade is refused with HTTP 503 until one closes. Other clients
// are not affected.
func TestAnonymousChannelLimitPerClient(t *testing.T) {
	h := newHarness(t, Operations{})
	var clients []*testClient
	for range MaxAnonymousPerClient {
		clients = append(clients, h.dialFrom("203.0.113.1"))
	}
	if _, err := h.tryDial("203.0.113.1", nil); !errors.Is(err, errRefused) {
		t.Fatalf("5th channel: %v", err)
	}
	h.dialFrom("203.0.113.2")
	clients[0].ws.Close(websocket.StatusNormalClosure, "")
	h.waitAnonymous(t, MaxAnonymousPerClient)
	h.dialFrom("203.0.113.1")
}

// Anonymous channels are also bounded server-wide, across clients.
func TestAnonymousChannelLimitServerWide(t *testing.T) {
	h := newHarness(t, Operations{})
	for i := range MaxAnonymousChannels {
		h.dialFrom(fmt.Sprintf("203.0.113.%d", i/MaxAnonymousPerClient+1))
	}
	if _, err := h.tryDial("198.51.100.1", nil); !errors.Is(err, errRefused) {
		t.Fatalf("channel over the anonymous budget: %v", err)
	}
}

// A session channel leaves the anonymous budget once its hello is accepted,
// so approved devices keep working while anonymous channels are full; the
// total stays bounded by MaxChannels.
func TestAuthenticatedChannelsLeaveTheAnonymousBudget(t *testing.T) {
	h := newHarness(t, Operations{})
	sessions := 0
	for device := 1; sessions < MaxChannels; device++ {
		_, _, token := h.approved(fmt.Sprintf("user-%d", device), byte(device))
		for range MaxChannelsPerDevice {
			if _, first := h.helloFrom("192.0.2.1", PurposeSession, token); first.MessageType() != "ready" {
				t.Fatalf("session %d: %#v", sessions, first)
			}
			sessions++
		}
	}
	h.waitAnonymous(t, 0)
	if _, err := h.tryDial("192.0.2.9", nil); !errors.Is(err, errRefused) {
		t.Fatalf("channel over the total: %v", err)
	}
}

// The hello must arrive within 10 s of the upgrade.
func TestHelloTimeout(t *testing.T) {
	h := newHarness(t, Operations{})
	c := h.dial()
	h.clock.waitTimer(t, HelloTimeout)
	h.clock.Advance(HelloTimeout - time.Millisecond)
	if h.listener.Registry().Len() != 1 {
		t.Fatal("closed early")
	}
	h.clock.Advance(time.Millisecond)
	if status := c.closed(); status != websocket.StatusPolicyViolation {
		t.Fatal(status)
	}
}

func TestSessionHello(t *testing.T) {
	h := newHarness(t, Operations{})
	user, device, token := h.approved("sub", 1)
	c, first := h.hello(PurposeSession, token)
	if _, ok := first.(Ready); !ok {
		t.Fatalf("%#v", first)
	}
	conns := h.listener.Registry().Device(device.ID)
	if len(conns) != 1 || conns[0].Principal().UserID != user.ID || len(h.listener.Registry().User(user.ID)) != 1 {
		t.Fatal("registry by user and device")
	}
	c.ws.Close(websocket.StatusNormalClosure, "")
	deadline := time.Now().Add(5 * time.Second)
	for len(h.listener.Registry().Device(device.ID)) != 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if len(h.listener.Registry().Device(device.ID)) != 0 {
		t.Fatal("closed channel still registered")
	}
}

// Hello errors carry no op and close the channel.
func TestHelloErrors(t *testing.T) {
	h := newHarness(t, Operations{})
	_, device, token := h.approved("sub", 1)
	expired := func() {
		h.clock.Advance(accounts.AccessLifetime)
	}
	for _, tc := range []struct {
		name    string
		purpose Purpose
		token   string
		before  func()
		code    ErrorCode
	}{
		{"unknown token", PurposeSession, "lfa_" + strings.Repeat("A", 43), nil, CodeUnauthorized},
		{"enroll not yet served", PurposeEnroll, "", nil, CodeUnsupportedVersion},
		{"refresh not yet served", PurposeRefresh, "", nil, CodeUnsupportedVersion},
		{"expired by the server clock", PurposeSession, token, expired, CodeTokenExpired},
	} {
		if tc.before != nil {
			tc.before()
		}
		c, first := h.hello(tc.purpose, tc.token)
		expectError(t, first, 0, tc.code)
		if status := c.closed(); status != websocket.StatusNormalClosure {
			t.Errorf("%s: close %d", tc.name, status)
		}
	}
	// Pending and revoked states.
	h2 := newHarness(t, Operations{})
	user, device, token := h2.approved("sub", 1)
	_ = h2.store.SetDeviceState(context.Background(), device.ID, accounts.DeviceRevoked, accounts.AdminActor("test"))
	_ = device
	h2.poll()
	_, first := h2.hello(PurposeSession, token)
	expectError(t, first, 0, CodeRevoked) // the revoked access token is recognized
	_, device2, token2 := h2.approved("other", 2)
	_ = h2.store.SetUserState(context.Background(), device2.UserID, accounts.UserRevoked, accounts.AdminActor("test"))
	h2.poll()
	_, first = h2.hello(PurposeSession, token2)
	expectError(t, first, 0, CodeRevoked)
	_ = user
	pending, _, _ := h2.store.EnsureUser(context.Background(), "google", "pending", "")
	key := bytes.Repeat([]byte{9}, 65)
	key[0] = 0x04
	pendingDevice, _ := h2.store.AddDevice(context.Background(), pending.ID, "Mac", key)
	pendingToken, _, _ := h2.store.IssueAccess(context.Background(), pendingDevice.ID)
	h2.poll()
	_, first = h2.hello(PurposeSession, pendingToken)
	expectError(t, first, 0, CodeNotApproved)
	_ = device
}

// A malformed or unsupported hello that still names a reply key gets a sealed
// error; one without a usable reply key is closed with no reply.
func TestHelloDecodeFailures(t *testing.T) {
	h := newHarness(t, Operations{})
	send := func(plaintext string, replyKey []byte) *testClient {
		c := h.dial()
		key := newKey(t)
		if replyKey == nil {
			replyKey = key.PublicKey().Bytes()
		}
		c.channel, _ = NewClient(h.identity.PublicKey(), key)
		sealed, _ := c.channel.Hello([]byte(strings.ReplaceAll(plaintext, "KEY", b64(replyKey))))
		_ = c.ws.Write(context.Background(), websocket.MessageBinary, sealed)
		return c
	}
	c := send(`{"schema_version":2,"type":"hello","reply_key":"KEY","purpose":"session"}`, nil)
	expectError(t, c.recv(), 0, CodeUnsupportedVersion)
	c = send(`{"schema_version":1,"type":"hello","reply_key":"KEY","purpose":"session"}`, nil)
	expectError(t, c.recv(), 0, CodeInvalidMessage)
	c = send(`{"schema_version":1,"type":"hello","purpose":"session"}`, nil)
	if status := c.closed(); status != websocket.StatusPolicyViolation {
		t.Fatal(status)
	}
}

// Two session channels per device; the third is busy.
func TestChannelsPerDevice(t *testing.T) {
	h := newHarness(t, Operations{})
	_, _, token := h.approved("sub", 1)
	for range MaxChannelsPerDevice {
		if _, first := h.hello(PurposeSession, token); first.MessageType() != "ready" {
			t.Fatalf("%#v", first)
		}
	}
	_, first := h.hello(PurposeSession, token)
	expectError(t, first, 0, CodeBusy)
}

func TestIdleTimeoutAndPing(t *testing.T) {
	h := newHarness(t, Operations{})
	_, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)
	h.clock.waitTimer(t, IdleTimeout)
	h.clock.waitTimer(t, PingInterval)
	// The client answers pings only while it reads.
	status := make(chan websocket.StatusCode, 1)
	go func() { status <- c.closed() }()
	h.clock.Advance(PingInterval)
	deadline := time.Now().Add(5 * time.Second)
	for c.pings.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if c.pings.Load() != 1 {
		t.Fatal("no ping after 15 s")
	}
	h.clock.Advance(IdleTimeout - PingInterval - time.Millisecond)
	select {
	case s := <-status:
		t.Fatalf("closed before 30 s idle: %d", s)
	case <-time.After(20 * time.Millisecond):
	}
	h.clock.Advance(time.Millisecond)
	if s := <-status; s != websocket.StatusNormalClosure {
		t.Fatal(s)
	}
}

// fakeDictation stands in for the dictation operation: it counts audio bytes
// and answers dictation_end with dictation_complete.
type fakeDictation struct {
	conn    *Conn
	op      int64
	samples int
	done    chan struct{}
	closed  atomic.Bool
}

func (d *fakeDictation) Control(ctx context.Context, m Message) error {
	end, ok := m.(DictationEnd)
	if !ok {
		return invalid("unexpected message")
	}
	if int(end.TotalSamples) != d.samples {
		return invalid("sample count mismatch")
	}
	if err := d.conn.Send(ctx, DictationComplete{Op: d.op, Windows: 0}); err != nil {
		return err
	}
	close(d.done)
	return nil
}

func (d *fakeDictation) Audio(_ context.Context, samples []byte) error {
	d.samples += len(samples) / 4
	return nil
}

func (d *fakeDictation) Done() <-chan struct{} { return d.done }
func (d *fakeDictation) Close()                { d.closed.Store(true) }

func TestOperationHooks(t *testing.T) {
	var dictations []*fakeDictation
	var mu sync.Mutex
	operations := Operations{PurposeSession: {
		"dictation_start": func(ctx context.Context, c *Conn, m Message) (Operation, error) {
			start := m.(DictationStart)
			d := &fakeDictation{conn: c, op: start.Op, done: make(chan struct{})}
			mu.Lock()
			dictations = append(dictations, d)
			mu.Unlock()
			return d, c.Send(ctx, DictationAccepted{Op: start.Op, WindowSamples: WindowSamples,
				Model: ModelIdentity{Engine: "e", ModelID: "m", ModelRevision: "r", ManifestHash: "h", SDK: "s", WorkerBuild: "w"}})
		},
		"rewrite": func(ctx context.Context, c *Conn, m Message) (Operation, error) {
			rewrite := m.(Rewrite)
			if c.Principal().DeviceID == 0 || len(c.Binding()) != 32 {
				return nil, &Error{CodeInternal, "no principal"}
			}
			if bytes.Contains(rewrite.Request, []byte("busy")) {
				return nil, &Error{CodeBusy, "test"}
			}
			return nil, c.Send(ctx, RewriteEvent{Op: rewrite.Op, Event: json.RawMessage(`{"event":"accepted"}`)})
		},
	}}
	h := newHarness(t, operations)
	_, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)

	c.send(DictationStart{Op: 1, Format: AudioFormat, SampleRate: SampleRate})
	if m := c.recv(); m.MessageType() != "dictation_accepted" {
		t.Fatalf("%#v", m)
	}
	c.sendFrame(Frame{KindAudio, make([]byte, 400)})
	c.sendFrame(Frame{KindAudio, make([]byte, 40)})
	c.send(DictationEnd{Op: 1, TotalSamples: 110})
	if m, ok := c.recv().(DictationComplete); !ok || m.Op != 1 {
		t.Fatalf("%#v", m)
	}
	deadline := time.Now().Add(5 * time.Second)
	for !dictations[0].closed.Load() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !dictations[0].closed.Load() {
		t.Fatal("finished operation not closed")
	}
	// A synchronous operation, then one that fails: the error carries the op
	// and the channel stays open for the next operation.
	c.send(Rewrite{Op: 2, Request: json.RawMessage(`{"text":"ok"}`)})
	if m, ok := c.recv().(RewriteEvent); !ok || m.Op != 2 {
		t.Fatalf("%#v", m)
	}
	c.send(Rewrite{Op: 3, Request: json.RawMessage(`{"text":"busy"}`)})
	expectError(t, c.recv(), 3, CodeBusy)
	c.send(Rewrite{Op: 4, Request: json.RawMessage(`{"text":"ok"}`)})
	if m, ok := c.recv().(RewriteEvent); !ok || m.Op != 4 {
		t.Fatalf("%#v", m)
	}
	// op numbers must increase within the channel.
	c.send(Rewrite{Op: 4, Request: json.RawMessage(`{}`)})
	expectError(t, c.recv(), 0, CodeInvalidMessage)
	if status := c.closed(); status != websocket.StatusNormalClosure {
		t.Fatal(status)
	}
}

func TestOperationRefusals(t *testing.T) {
	operations := Operations{PurposeSession: {
		"dictation_start": func(ctx context.Context, c *Conn, m Message) (Operation, error) {
			return &fakeDictation{conn: c, op: m.(DictationStart).Op, done: make(chan struct{})}, nil
		},
	}}
	h := newHarness(t, operations)
	_, _, token := h.approved("sub", 1)
	for name, tc := range map[string]struct {
		frames []Frame
		op     int64
		code   ErrorCode
	}{
		"audio outside an operation": {[]Frame{{KindAudio, make([]byte, 8)}}, 0, CodeInvalidMessage},
		"type with no operation":     {[]Frame{control(t, Refresh{Op: 1, RefreshToken: "lfr_" + strings.Repeat("A", 43), Signature: make([]byte, 8)})}, 0, CodeInvalidMessage},
		"server-only type":           {[]Frame{control(t, Cancelled{Op: 1})}, 0, CodeInvalidMessage},
		"undecodable control":        {[]Frame{{KindControl, []byte(`{"schema_version":1,"type":"nope"}`)}}, 0, CodeInvalidMessage},
		"newer schema version":       {[]Frame{{KindControl, []byte(`{"schema_version":2,"type":"nope"}`)}}, 0, CodeUnsupportedVersion},
		"wrong op during operation": {[]Frame{
			control(t, DictationStart{Op: 5, Format: AudioFormat, SampleRate: SampleRate}),
			control(t, DictationEnd{Op: 6, TotalSamples: 0}),
		}, 5, CodeInvalidMessage},
		"second operation while one runs": {[]Frame{
			control(t, DictationStart{Op: 5, Format: AudioFormat, SampleRate: SampleRate}),
			control(t, DictationStart{Op: 6, Format: AudioFormat, SampleRate: SampleRate}),
		}, 5, CodeInvalidMessage},
		"operation error": {[]Frame{
			control(t, DictationStart{Op: 5, Format: AudioFormat, SampleRate: SampleRate}),
			control(t, DictationEnd{Op: 5, TotalSamples: 9}),
		}, 5, CodeInvalidMessage},
		"audio over 16,000 samples": {[]Frame{
			control(t, DictationStart{Op: 5, Format: AudioFormat, SampleRate: SampleRate}),
			{KindAudio, make([]byte, 4*(MaxAudioSamples+1))},
		}, 5, CodeLimitExceeded},
	} {
		c, _ := h.hello(PurposeSession, token)
		for _, frame := range tc.frames {
			if frame.Kind == KindAudio && len(frame.Payload) > 4*MaxAudioSamples {
				sealed, _ := c.channel.sealPlaintext(frame.plaintext())
				_ = c.ws.Write(context.Background(), websocket.MessageBinary, sealed)
				continue
			}
			c.sendFrame(frame)
		}
		m := c.recv()
		e, ok := m.(ErrorMessage)
		if !ok || e.Code != tc.code || e.Op != tc.op {
			t.Errorf("%s: %#v", name, m)
		}
		if name == "operation error" {
			// The failed operation ends; the channel may start another.
			c.send(DictationStart{Op: 7, Format: AudioFormat, SampleRate: SampleRate})
			c.send(DictationCancel{Op: 8})
			expectError(t, c.recv(), 7, CodeInvalidMessage)
		}
		c.ws.CloseNow()
	}
}

func control(t *testing.T, m Message) Frame {
	t.Helper()
	data, err := EncodeMessage(m)
	if err != nil {
		t.Fatal(err)
	}
	return Frame{KindControl, data}
}

// A sequence failure closes with no reply.
func TestSequenceFailureClosesSilently(t *testing.T) {
	h := newHarness(t, Operations{})
	_, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)
	sealed, _ := c.channel.Seal(control(t, DictationCancel{Op: 1}))
	sealed[0] ^= 0xff
	_ = c.ws.Write(context.Background(), websocket.MessageBinary, sealed)
	if status := c.closed(); status != websocket.StatusPolicyViolation {
		t.Fatal(status)
	}
}

// Revoke closes every channel of the user or device with a sealed
// error{code:"revoked"}; other users' channels stay open.
func TestRevokeClosesAffectedChannels(t *testing.T) {
	h := newHarness(t, Operations{})
	_, device, token := h.approved("a", 1)
	other, _, otherToken := h.approved("b", 2)
	c1, _ := h.hello(PurposeSession, token)
	c2, _ := h.hello(PurposeSession, token)
	c3, _ := h.hello(PurposeSession, otherToken)
	h.listener.Revoke(accounts.Lost{Devices: []int64{device.ID}})
	for _, c := range []*testClient{c1, c2} {
		expectError(t, c.recv(), 0, CodeRevoked)
		if status := c.closed(); status != websocket.StatusNormalClosure {
			t.Fatal(status)
		}
	}
	if len(h.listener.Registry().User(other.ID)) != 1 {
		t.Fatal("other user's channel closed")
	}
	h.listener.Revoke(accounts.Lost{Users: []int64{other.ID}})
	expectError(t, c3.recv(), 0, CodeRevoked)
}

// Logs carry IDs, counts and codes only: no tokens, keys or bodies.
func TestLogsAreContentFree(t *testing.T) {
	h := newHarness(t, Operations{})
	_, _, token := h.approved("sub", 1)
	c, _ := h.hello(PurposeSession, token)
	c.send(DictationCancel{Op: 1})
	c.recv()
	c.closed()
	h.hello(PurposeSession, "lfa_"+strings.Repeat("A", 43))
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) && !strings.Contains(h.logs.String(), "unauthorized") {
		time.Sleep(5 * time.Millisecond)
	}
	logs := h.logs.String()
	for _, secret := range []string{token, "lfa_", b64(h.identity.PublicKey()), "dictation_cancel"} {
		if strings.Contains(logs, secret) {
			t.Fatalf("log contains %q:\n%s", secret, logs)
		}
	}
	if !strings.Contains(logs, "code=unauthorized") {
		t.Fatalf("expected coded log lines:\n%s", logs)
	}
	if errors.Is(nil, ErrChannelFailed) {
		t.Fatal()
	}
}
