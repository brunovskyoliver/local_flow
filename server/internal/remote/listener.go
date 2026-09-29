package remote

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"localflow/server/internal/accounts"
)

// Bounds and timers of the remote listener (contract "Timeouts", research R11).
//
// A channel is anonymous from the upgrade until a session hello authenticates
// it; enroll and refresh channels stay anonymous. Anonymous channels have
// their own budget, server-wide and per client, so nobody without an
// approved device can hold the slots approved devices need.
const (
	MaxChannels           = 32
	MaxAnonymousChannels  = 16
	MaxAnonymousPerClient = 4
	MaxChannelsPerDevice  = 2
	HelloTimeout          = 10 * time.Second
	IdleTimeout           = 30 * time.Second
	EnrollIdleTimeout     = 5 * time.Minute
	PingInterval          = 15 * time.Second
	writeTimeout          = 10 * time.Second
)

// Clock is the listener's time source; tests inject a manual one.
type Clock interface {
	Now() time.Time
	AfterFunc(d time.Duration, f func()) Timer
}

// Timer is a pending AfterFunc.
type Timer interface{ Stop() bool }

type systemClock struct{}

func (systemClock) Now() time.Time                            { return time.Now() }
func (systemClock) AfterFunc(d time.Duration, f func()) Timer { return time.AfterFunc(d, f) }

// SystemClock is the production Clock.
var SystemClock Clock = systemClock{}

// Accounts supplies the current account snapshot (accounts.Watcher).
type Accounts interface{ Snapshot() *accounts.Snapshot }

// OperationStart begins an operation for its first control message. It runs
// on the channel's reader, so it must not block for long. Returning a nil
// Operation means the operation finished during the call (its replies are
// sent). An *Error is answered with error{op, code} and ends the operation;
// the channel stays open unless the code is revoked. Any other error closes
// the channel after an internal error.
type OperationStart func(ctx context.Context, c *Conn, m Message) (Operation, error)

// Operation is a running operation. The listener delivers every later frame
// of the channel to it until Done is closed: control messages with the same op
// to Control, audio payloads to Audio. Errors from either behave as the
// OperationStart errors. Close is called exactly once when the operation ends
// for any reason, including the channel closing, and must release everything
// the operation holds.
type Operation interface {
	Control(ctx context.Context, m Message) error
	Audio(ctx context.Context, samples []byte) error
	Done() <-chan struct{}
	Close()
}

// Operations maps a hello purpose and an operation's first message type to its
// start function, e.g. {PurposeSession: {"dictation_start": …, "rewrite": …}}.
// A purpose other than session with no operations is answered
// unsupported_version at the hello.
type Operations map[Purpose]map[string]OperationStart

// Config configures a Listener.
type Config struct {
	Identity      *accounts.Identity
	Accounts      Accounts
	ServerVersion string
	Clock         Clock
	Logger        *log.Logger
	Operations    Operations
	// Audit, when set, records a content-free audit row. The listener uses
	// it for cross_user_attempt on authenticated channels (Feature 014 T085).
	Audit func(accounts.AuditEntry)
}

// Listener serves GET /v1/remote/identity and GET /v1/remote/channel and
// nothing else.
type Listener struct {
	cfg      Config
	identity []byte
	registry *Registry
	nextID   atomic.Uint64

	slotsMu   sync.Mutex     // guards the channel counts
	open      int            // every channel
	anonymous int            // channels not bound to a session principal
	byClient  map[string]int // anonymous channels per client

	helloMu       sync.Mutex             // guards the hello times
	accountHellos []time.Time            // recent enroll and refresh hellos, server-wide
	clientHellos  map[string][]time.Time // the same, per client
}

// Enroll and refresh hellos are admitted up to MaxAccountHellos per client
// and MaxAccountHellosTotal server-wide per AccountHelloWindow; more are
// answered busy (research R11).
const (
	MaxAccountHellos      = 10
	MaxAccountHellosTotal = 60
	AccountHelloWindow    = time.Minute
	// revokeGrace bounds how long a revoked channel waits for its sealed
	// error to be written before it is closed regardless.
	revokeGrace = 300 * time.Millisecond
)

// clientAddress names the client for per-client limits. flowd listens on
// loopback only and cloudflared sets Cf-Connecting-Ip from the Cloudflare
// edge, which overwrites any value the client sent; without the tunnel (a
// direct loopback connection) the peer address is used.
func clientAddress(r *http.Request) string {
	if ip := r.Header.Get("Cf-Connecting-Ip"); ip != "" {
		return ip
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// admitChannel takes an anonymous slot for a new channel from client.
func (l *Listener) admitChannel(client string) bool {
	l.slotsMu.Lock()
	defer l.slotsMu.Unlock()
	if l.open >= MaxChannels || l.anonymous >= MaxAnonymousChannels || l.byClient[client] >= MaxAnonymousPerClient {
		return false
	}
	l.open++
	l.anonymous++
	l.byClient[client]++
	return true
}

// authenticated moves c out of the anonymous budget once its session hello
// has been accepted.
func (l *Listener) authenticated(c *Conn) {
	l.slotsMu.Lock()
	defer l.slotsMu.Unlock()
	if c.anonymous {
		c.anonymous = false
		l.leaveAnonymousLocked(c.client)
	}
}

func (l *Listener) releaseChannel(c *Conn) {
	l.slotsMu.Lock()
	defer l.slotsMu.Unlock()
	l.open--
	if c.anonymous {
		c.anonymous = false
		l.leaveAnonymousLocked(c.client)
	}
}

func (l *Listener) leaveAnonymousLocked(client string) {
	l.anonymous--
	if l.byClient[client]--; l.byClient[client] <= 0 {
		delete(l.byClient, client)
	}
}

// admitAccountHello applies the per-client and server-wide enroll and
// refresh hello limits over a sliding minute of the listener's clock.
func (l *Listener) admitAccountHello(client string) bool {
	l.helloMu.Lock()
	defer l.helloMu.Unlock()
	now := l.cfg.Clock.Now()
	recent := func(times []time.Time) []time.Time {
		kept := times[:0]
		for _, at := range times {
			if now.Sub(at) < AccountHelloWindow {
				kept = append(kept, at)
			}
		}
		return kept
	}
	l.accountHellos = recent(l.accountHellos)
	for key, times := range l.clientHellos {
		if kept := recent(times); len(kept) == 0 {
			delete(l.clientHellos, key)
		} else {
			l.clientHellos[key] = kept
		}
	}
	if len(l.accountHellos) >= MaxAccountHellosTotal || len(l.clientHellos[client]) >= MaxAccountHellos {
		return false
	}
	l.accountHellos = append(l.accountHellos, now)
	l.clientHellos[client] = append(l.clientHellos[client], now)
	return true
}

// NewListener builds the handler. Clock defaults to SystemClock and Logger to
// a discarding logger.
func NewListener(cfg Config) *Listener {
	if cfg.Clock == nil {
		cfg.Clock = SystemClock
	}
	if cfg.Logger == nil {
		cfg.Logger = log.New(discard{}, "", 0)
	}
	body, _ := json.Marshal(Identity{
		SchemaVersion: SchemaVersion, Server: "flowd/" + cfg.ServerVersion, ProtocolVersions: []int{1},
		Suite: Suite, ServerKey: cfg.Identity.PublicKey(), Fingerprint: cfg.Identity.Fingerprint(),
	})
	return &Listener{cfg: cfg, identity: body, registry: newRegistry(), byClient: map[string]int{}, clientHellos: map[string][]time.Time{}}
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

// Listen opens a TCP listener on a loopback IP literal only: cloudflared
// connects locally, and nothing else may reach the remote routes.
func Listen(addr string) (net.Listener, error) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, errors.New("remote listen must be host:port")
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return nil, errors.New("remote listen host must be a loopback IP literal")
	}
	return net.Listen("tcp", addr)
}

// Registry returns the live-channel registry.
func (l *Listener) Registry() *Registry { return l.registry }

func (l *Listener) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/v1/remote/identity":
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(l.identity)
	case r.Method == http.MethodGet && r.URL.Path == "/v1/remote/channel":
		client := clientAddress(r)
		if !l.admitChannel(client) {
			l.cfg.Logger.Printf("remote event=refused code=busy")
			http.Error(w, "busy", http.StatusServiceUnavailable)
			return
		}
		c := &Conn{id: l.nextID.Add(1), listener: l, client: client, anonymous: true, done: make(chan struct{}), outcome: "closed"}
		defer l.releaseChannel(c)
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		c.socket = newSocket(ws)
		l.registry.add(c)
		defer l.registry.remove(c)
		l.serveChannel(r.Context(), c)
	default:
		http.NotFound(w, r)
	}
}

// Revoke closes every channel of the listed users and devices with a sealed
// error{code:"revoked"} (connected to accounts.Watcher's callback). A channel
// whose error cannot be written within revokeGrace (a client that stopped
// reading, or an operation holding the send lock) is closed without it, so
// revocation never waits for the 10 s write timeout.
func (l *Listener) Revoke(lost accounts.Lost) {
	for _, c := range l.registry.affected(lost) {
		go c.revoke()
	}
}

func (c *Conn) revoke() {
	c.setOutcome(string(CodeRevoked))
	sent := make(chan struct{})
	go func() {
		defer close(sent)
		ctx, cancel := context.WithTimeout(context.Background(), revokeGrace)
		defer cancel()
		_ = c.Send(ctx, NewError(c.runningOp(), CodeRevoked))
	}()
	timer := time.NewTimer(revokeGrace)
	defer timer.Stop()
	select {
	case <-sent:
		c.closeWith(websocket.StatusNormalClosure, string(CodeRevoked))
	case <-timer.C:
		// Not writable: a close handshake would wait for the same stuck
		// socket, so the connection is dropped at once.
		c.shutdown(string(CodeRevoked), func() { _ = c.socket.ws.CloseNow() })
	}
}

// CloseAll closes every channel without a reply (shutdown).
func (l *Listener) CloseAll() {
	for _, c := range l.registry.all() {
		c.closeWith(websocket.StatusGoingAway, "shutdown")
	}
}

func authCode(err error) ErrorCode {
	switch {
	case errors.Is(err, accounts.ErrTokenExpired):
		return CodeTokenExpired
	case errors.Is(err, accounts.ErrNotApproved):
		return CodeNotApproved
	case errors.Is(err, accounts.ErrRevoked):
		return CodeRevoked
	}
	return CodeUnauthorized
}

func (l *Listener) serveChannel(ctx context.Context, c *Conn) {
	started := l.cfg.Clock.Now()
	defer func() {
		c.closeWith(websocket.StatusNormalClosure, "")
		c.endOperation()
		l.cfg.Logger.Printf("remote channel=%d purpose=%s user=%d device=%d ops=%d duration_ms=%d code=%s",
			c.id, c.purpose, c.principal.UserID, c.principal.DeviceID, c.operations, l.cfg.Clock.Now().Sub(started).Milliseconds(), c.outcomeCode())
	}()
	helloTimer := l.cfg.Clock.AfterFunc(HelloTimeout, func() { c.closeWith(websocket.StatusPolicyViolation, "hello_timeout") })
	channel, plaintext, err := acceptHello(ctx, c.socket, l.cfg.Identity.PrivateKey())
	helloTimer.Stop()
	if err != nil {
		if errors.Is(err, ErrHelloRefused) {
			c.setOutcome("hello_refused")
		}
		return
	}
	c.mu.Lock()
	c.channel = channel
	c.mu.Unlock()
	hello, err := DecodeHello(plaintext)
	if len(hello.ReplyKey) != KeyBytes || channel.Accept(hello.ReplyKey) != nil {
		c.closeWith(websocket.StatusPolicyViolation, "no_reply_key")
		return
	}
	if err != nil {
		c.Fail(0, CodeOf(err))
		return
	}
	c.purpose = hello.Purpose
	switch hello.Purpose {
	case PurposeSession:
		snapshot := l.cfg.Accounts.Snapshot()
		principal, err := snapshot.Authenticate(hello.AccessToken, l.cfg.Clock.Now())
		if err != nil {
			c.Fail(0, authCode(err))
			return
		}
		// Feature 014 T067: operations refuse to start once the hello's
		// access token has expired (token_expired at an operation start).
		device, _ := snapshot.Device(principal.DeviceID)
		c.accessExpires = device.AccessExpiresAt
		if !l.registry.bind(c, principal) {
			c.Fail(0, CodeBusy)
			return
		}
		l.authenticated(c)
		// A revocation that swapped the snapshot after Authenticate read it
		// and walked the registry before bind would miss this channel; the
		// watcher swaps before it calls Revoke, so re-checking the current
		// snapshot after bind closes that window.
		if _, err := l.cfg.Accounts.Snapshot().Authenticate(hello.AccessToken, l.cfg.Clock.Now()); err != nil {
			c.Fail(0, authCode(err))
			return
		}
	default:
		if len(l.cfg.Operations[hello.Purpose]) == 0 {
			c.Fail(0, CodeUnsupportedVersion)
			return
		}
		if !l.admitAccountHello(c.client) {
			l.cfg.Logger.Printf("remote channel=%d purpose=%s event=rate_limited code=busy", c.id, hello.Purpose)
			c.Fail(0, CodeBusy)
			return
		}
	}
	c.mu.Lock()
	c.readyAt = l.cfg.Clock.Now()
	c.mu.Unlock()
	if err := c.Send(ctx, Ready{}); err != nil {
		return
	}
	c.armIdle()
	c.armPing()
	for {
		message, err := c.socket.read(ctx)
		if err != nil {
			return
		}
		c.mu.Lock()
		frame, err := c.channel.Open(message)
		c.mu.Unlock()
		if errors.Is(err, ErrChannelFailed) {
			c.closeWith(websocket.StatusPolicyViolation, "sequence")
			return
		}
		if err != nil {
			c.Fail(c.runningOp(), CodeOf(err))
			return
		}
		if !c.handle(ctx, frame) {
			return
		}
	}
}

// Conn is one live channel. Operations use it to send sealed control
// messages; every identity it reports comes from the hello, never from a
// later message (FR-024).
type Conn struct {
	id        uint64
	listener  *Listener
	socket    *socket
	client    string // for per-client limits only; never logged
	anonymous bool   // counted in the anonymous budget; guarded by listener.slotsMu
	purpose   Purpose
	principal accounts.Principal
	// accessExpires is the expiry of the hello's access token (session only).
	accessExpires time.Time

	sendMu     sync.Mutex // held across seal and write so frames leave in seq order
	mu         sync.Mutex // guards channel and the fields below
	channel    *Channel
	current    Operation
	currentOp  int64
	lastOp     int64
	operations int
	readyAt    time.Time
	idle       Timer
	ping       Timer
	outcome    string
	closeOnce  sync.Once
	done       chan struct{}
}

// ID is the channel's process-local number, for logs.
func (c *Conn) ID() uint64 { return c.id }

// Purpose is the hello's purpose.
func (c *Conn) Purpose() Purpose { return c.purpose }

// Principal is the user and device of a session channel (zero otherwise).
func (c *Conn) Principal() accounts.Principal { return c.principal }

// AccessExpiresAt is when the session hello's access token expires by the
// server clock (zero for other purposes). Operations compare it with Now at
// their start and answer token_expired once it has passed.
func (c *Conn) AccessExpiresAt() time.Time { return c.accessExpires }

// ReadyAt is when the server sent ready, by the listener's clock. Enrollment
// is accepted only within EnrollIdleTimeout of it.
func (c *Conn) ReadyAt() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.readyAt
}

// Binding is the channel binding for OIDC nonces and device signatures.
func (c *Conn) Binding() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.channel.Binding()
}

// Now is the listener's clock.
func (c *Conn) Now() time.Time { return c.listener.cfg.Clock.Now() }

// Done is closed when the channel closes.
func (c *Conn) Done() <-chan struct{} { return c.done }

var errConnClosed = errors.New("remote: channel closed")

// Send seals and writes one control message.
func (c *Conn) Send(ctx context.Context, m Message) error {
	data, err := EncodeMessage(m)
	if err != nil {
		return err
	}
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	select {
	case <-c.done:
		return errConnClosed
	default:
	}
	c.mu.Lock()
	sealed, err := c.channel.Seal(Frame{KindControl, data})
	c.mu.Unlock()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	return c.socket.write(ctx, sealed)
}

// Fail sends a sealed error (op 0 for none) and closes the channel.
func (c *Conn) Fail(op int64, code ErrorCode) {
	c.setOutcome(string(code))
	_ = c.Send(context.Background(), NewError(op, code))
	c.closeWith(websocket.StatusNormalClosure, string(code))
}

// Close closes the channel without a reply.
func (c *Conn) Close() { c.closeWith(websocket.StatusNormalClosure, "") }

func (c *Conn) setOutcome(outcome string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.outcome == "closed" {
		c.outcome = outcome
	}
}

func (c *Conn) outcomeCode() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.outcome
}

func (c *Conn) closeWith(code websocket.StatusCode, reason string) {
	c.shutdown(reason, func() { c.socket.close(code) })
}

// shutdown ends the channel once: it records reason, stops the timers,
// closes Done and runs closeSocket in the background.
func (c *Conn) shutdown(reason string, closeSocket func()) {
	c.closeOnce.Do(func() {
		if reason != "" {
			c.setOutcome(reason)
		}
		c.mu.Lock()
		for _, timer := range []Timer{c.idle, c.ping} {
			if timer != nil {
				timer.Stop()
			}
		}
		c.mu.Unlock()
		close(c.done)
		go closeSocket()
	})
}

func (c *Conn) closed() bool {
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}

func (c *Conn) running() (int64, Operation) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.currentOp, c.current
}

func (c *Conn) runningOp() int64 {
	op, _ := c.running()
	return op
}

// handle dispatches one authentic frame after ready. It returns false once
// the channel has been closed.
func (c *Conn) handle(ctx context.Context, frame Frame) bool {
	op, running := c.running()
	// Feature 014 T085: an operation that has already ended (Done closed, for
	// example right after dictation_complete) is finished before dispatch, so
	// the client's next operation is not mistaken for a stray op while the
	// begin goroutine has yet to run, and later audio is outside any operation.
	if running != nil {
		select {
		case <-running.Done():
			c.finish(running)
			op, running = 0, nil
		default:
		}
	}
	if frame.Kind == KindAudio {
		if running == nil {
			c.Fail(0, CodeInvalidMessage)
			return false
		}
		return c.operationResult(op, running, running.Audio(ctx, frame.Payload))
	}
	message, err := DecodeMessage(frame.Payload)
	if err != nil {
		c.Fail(op, CodeOf(err))
		return false
	}
	numbered, ok := message.(opMessage)
	if running != nil {
		if !ok || numbered.OpNumber() != op {
			c.auditCrossUser()
			c.Fail(op, CodeInvalidMessage)
			return false
		}
		return c.operationResult(op, running, running.Control(ctx, message))
	}
	start, known := c.listener.cfg.Operations[c.purpose][message.MessageType()]
	c.mu.Lock()
	fresh := ok && numbered.OpNumber() > c.lastOp
	if fresh {
		c.lastOp = numbered.OpNumber()
		c.operations++
	}
	c.mu.Unlock()
	if !known || !fresh {
		c.auditCrossUser()
		c.Fail(0, CodeInvalidMessage)
		return false
	}
	op = numbered.OpNumber()
	c.stopIdle()
	operation, err := start(ctx, c, message)
	if operation != nil {
		c.begin(op, operation)
	} else {
		c.armIdle()
	}
	return c.operationResult(op, operation, err)
}

// auditCrossUser records a cross_user_attempt row when an authenticated
// channel names an operation it does not know: an op never started, one from
// another channel, a stale op or a message type this channel cannot start
// (contract "Errors"; Feature 014 T085). Only IDs and the code are written.
func (c *Conn) auditCrossUser() {
	audit := c.listener.cfg.Audit
	if audit == nil || c.purpose != PurposeSession || c.principal.DeviceID == 0 {
		return
	}
	audit(accounts.AuditEntry{
		Actor: accounts.DeviceActor(c.principal.DeviceID), Action: "cross_user_attempt",
		Target: accounts.UserTarget(c.principal.UserID), Outcome: string(CodeInvalidMessage),
	})
	c.listener.cfg.Logger.Printf("remote channel=%d user=%d device=%d event=cross_user_attempt code=%s",
		c.id, c.principal.UserID, c.principal.DeviceID, CodeInvalidMessage)
}

// operationResult applies an operation error: an *Error ends the operation
// with error{op, code} (revoked also closes); anything else closes after an
// internal error.
func (c *Conn) operationResult(op int64, operation Operation, err error) bool {
	if err == nil {
		return !c.closed()
	}
	var coded *Error
	if !errors.As(err, &coded) || coded.Code == CodeRevoked {
		c.Fail(op, CodeOf(err))
		return false
	}
	if operation != nil {
		c.finish(operation)
	}
	if err := c.Send(context.Background(), NewError(op, coded.Code)); err != nil {
		c.Close()
		return false
	}
	return true
}

func (c *Conn) begin(op int64, operation Operation) {
	c.mu.Lock()
	c.current, c.currentOp = operation, op
	c.mu.Unlock()
	go func() {
		select {
		case <-operation.Done():
		case <-c.done:
		}
		c.finish(operation)
	}()
}

// finish ends operation if it is still the current one.
func (c *Conn) finish(operation Operation) {
	c.mu.Lock()
	if c.current != operation {
		c.mu.Unlock()
		return
	}
	c.current, c.currentOp = nil, 0
	c.mu.Unlock()
	operation.Close()
	c.armIdle()
}

func (c *Conn) endOperation() {
	if _, operation := c.running(); operation != nil {
		c.finish(operation)
	}
}

// armIdle starts the between-operations timer: 30 s, or 5 minutes on an
// enrollment channel before its first operation.
func (c *Conn) armIdle() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed() {
		return
	}
	if c.idle != nil {
		c.idle.Stop()
	}
	timeout := IdleTimeout
	if c.purpose == PurposeEnroll && c.lastOp == 0 {
		timeout = EnrollIdleTimeout
	}
	c.idle = c.listener.cfg.Clock.AfterFunc(timeout, func() { c.closeWith(websocket.StatusNormalClosure, "idle") })
}

func (c *Conn) stopIdle() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.idle != nil {
		c.idle.Stop()
		c.idle = nil
	}
}

// armPing pings every 15 s; a ping that gets no pong closes the channel.
func (c *Conn) armPing() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed() {
		return
	}
	c.ping = c.listener.cfg.Clock.AfterFunc(PingInterval, func() {
		c.armPing()
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), PingInterval)
			defer cancel()
			if err := c.socket.ws.Ping(ctx); err != nil && !c.closed() {
				c.closeWith(websocket.StatusPolicyViolation, "ping")
			}
		}()
	})
}

// Registry holds live channels, by user and device once authenticated.
type Registry struct {
	mu       sync.Mutex
	conns    map[uint64]*Conn
	byUser   map[int64]map[uint64]*Conn
	byDevice map[int64]map[uint64]*Conn
}

func newRegistry() *Registry {
	return &Registry{conns: map[uint64]*Conn{}, byUser: map[int64]map[uint64]*Conn{}, byDevice: map[int64]map[uint64]*Conn{}}
}

func (r *Registry) add(c *Conn) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.conns[c.id] = c
}

// bind scopes c to principal, refusing a third channel for one device.
func (r *Registry) bind(c *Conn, principal accounts.Principal) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.byDevice[principal.DeviceID]) >= MaxChannelsPerDevice {
		return false
	}
	c.principal = principal
	insert(r.byUser, principal.UserID, c)
	insert(r.byDevice, principal.DeviceID, c)
	return true
}

func insert(index map[int64]map[uint64]*Conn, key int64, c *Conn) {
	if index[key] == nil {
		index[key] = map[uint64]*Conn{}
	}
	index[key][c.id] = c
}

func drop(index map[int64]map[uint64]*Conn, key int64, c *Conn) {
	delete(index[key], c.id)
	if len(index[key]) == 0 {
		delete(index, key)
	}
}

func (r *Registry) remove(c *Conn) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.conns, c.id)
	drop(r.byUser, c.principal.UserID, c)
	drop(r.byDevice, c.principal.DeviceID, c)
}

// Len counts open channels, authenticated or not.
func (r *Registry) Len() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.conns)
}

func collect(set map[uint64]*Conn) []*Conn {
	out := make([]*Conn, 0, len(set))
	for _, c := range set {
		out = append(out, c)
	}
	return out
}

// User returns the live channels of a user.
func (r *Registry) User(id int64) []*Conn {
	r.mu.Lock()
	defer r.mu.Unlock()
	return collect(r.byUser[id])
}

// Device returns the live channels of a device.
func (r *Registry) Device(id int64) []*Conn {
	r.mu.Lock()
	defer r.mu.Unlock()
	return collect(r.byDevice[id])
}

func (r *Registry) all() []*Conn {
	r.mu.Lock()
	defer r.mu.Unlock()
	return collect(r.conns)
}

// affected returns every channel of the listed users or devices, once each.
func (r *Registry) affected(lost accounts.Lost) []*Conn {
	r.mu.Lock()
	defer r.mu.Unlock()
	set := map[uint64]*Conn{}
	for _, id := range lost.Users {
		for key, c := range r.byUser[id] {
			set[key] = c
		}
	}
	for _, id := range lost.Devices {
		for key, c := range r.byDevice[id] {
			set[key] = c
		}
	}
	return collect(set)
}
