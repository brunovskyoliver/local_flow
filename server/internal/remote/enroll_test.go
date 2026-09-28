package remote

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"log"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"localflow/server/internal/accounts"
	"localflow/server/internal/oidc"
	"localflow/server/internal/oidc/oidctest"
)

const testAudience = "org.localflow.LocalFlow"

// accountsHarness is a listener serving the enroll and refresh operations
// with the real OIDC verifier; JWKS come from the repository's test key
// through a fake transport, so nothing touches the network.
type accountsHarness struct {
	*harness
	transport *oidctest.Transport
}

func newAccountsHarness(t *testing.T, googleClientIDs []string) *accountsHarness {
	t.Helper()
	clock := newManualClock()
	dir := filepath.Join(t.TempDir(), "data")
	store, err := accounts.Open(dir, clock.Now)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	h := &harness{t: t, clock: clock, store: store, logs: &lockedWriter{}}
	h.watcher, err = store.Watch(context.Background(), func(lost accounts.Lost) { h.listener.Revoke(lost) })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { h.watcher.Close() })
	h.identity, err = accounts.Keychain{Runner: &memoryKeychain{items: map[string]string{}}, Service: accounts.ServiceDevelopment}.Create(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	transport := oidctest.NewTransport(t)
	verifier, err := oidc.New(oidc.Config{
		AppleAudiences: []string{testAudience}, GoogleClientIDs: googleClientIDs,
		HTTPClient: transport.Client(), Now: clock.Now,
	})
	if err != nil {
		t.Fatal(err)
	}
	logger := log.New(h.logs, "", 0)
	h.listener = NewListener(Config{
		Identity: h.identity, Accounts: h.watcher, ServerVersion: "0.14.0", Clock: clock, Logger: logger,
		Operations: AccountOperations(AccountsConfig{
			Store: store, Verifier: verifier, Logger: logger,
			Reload: func(ctx context.Context) error { _, err := h.watcher.Poll(ctx); return err },
		}),
	})
	server := httptest.NewServer(h.listener)
	t.Cleanup(func() {
		h.listener.CloseAll()
		server.Close()
	})
	h.url = server.URL
	return &accountsHarness{harness: h, transport: transport}
}

// device is a stand-in for the client's Secure Enclave key.
type device struct {
	key    *ecdsa.PrivateKey
	public []byte
}

func newDevice(t *testing.T) *device {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	public, err := key.PublicKey.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	return &device{key: key, public: public}
}

func (d *device) sign(t *testing.T, parts ...[]byte) []byte {
	t.Helper()
	digest := sha256.Sum256(bytes.Join(parts, nil))
	signature, err := ecdsa.SignASN1(rand.Reader, d.key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return signature
}

// appleToken mints an Apple ID token for subject bound to binding, valid now
// by the harness clock.
func (h *accountsHarness) appleToken(subject string, binding []byte) string {
	now := h.clock.Now().Unix()
	return oidctest.Mint(h.t, nil, map[string]any{
		"iss": oidc.AppleIssuer, "aud": testAudience, "sub": subject, "iat": now, "exp": now + 600,
		"nonce": oidctest.AppleNonce(binding), "email": subject + "@example.com",
	})
}

// enroll opens an enroll channel and sends one signed enroll for subject.
func (h *accountsHarness) enroll(subject string, d *device) (*testClient, Message) {
	h.t.Helper()
	c, first := h.hello(PurposeEnroll, "")
	if first.MessageType() != "ready" {
		h.t.Fatalf("%#v", first)
	}
	return c, h.sendEnroll(c, 1, subject, d)
}

func (h *accountsHarness) sendEnroll(c *testClient, op int64, subject string, d *device) Message {
	h.t.Helper()
	binding := c.channel.Binding()
	c.send(Enroll{Op: op, Provider: "apple", IDToken: h.appleToken(subject, binding), DeviceName: "MacBook Pro",
		DeviceKey: d.public, Signature: d.sign(h.t, []byte(EnrollSignatureLabel), binding)})
	return c.recv()
}

func enrolled(t *testing.T, m Message, state string) Enrolled {
	t.Helper()
	e, ok := m.(Enrolled)
	if !ok || e.State != state || e.Op == 0 {
		t.Fatalf("got %#v, want enrolled %s", m, state)
	}
	return e
}

func auditActions(t *testing.T, store *accounts.Store) []string {
	t.Helper()
	entries, err := store.AuditLog(context.Background(), 100)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for i := len(entries) - 1; i >= 0; i-- {
		e := entries[i]
		out = append(out, e.Action+" "+e.Actor+" "+e.Target+" "+e.Outcome)
	}
	return out
}

func TestEnrollNewIdentity(t *testing.T) {
	ctx := context.Background()
	h := newAccountsHarness(t, nil)
	d := newDevice(t)
	c, reply := h.enroll("001234.abc", d)
	e := enrolled(t, reply, "pending")
	users, _ := h.store.Users(ctx)
	if len(users) != 1 || users[0].State != accounts.UserPending || users[0].Provider != "apple" ||
		users[0].Subject != "001234.abc" || users[0].Display != "001234.abc@example.com" {
		t.Fatalf("%+v", users)
	}
	devices, _ := h.store.Devices(ctx, users[0].ID)
	if len(devices) != 1 || devices[0].State != accounts.DevicePending || devices[0].Name != "MacBook Pro" ||
		!bytes.Equal(devices[0].PublicKey, d.public) {
		t.Fatalf("%+v", devices)
	}
	hash := accounts.HashToken(e.RefreshToken)
	if !bytes.Equal(devices[0].RefreshHash, hash[:]) {
		t.Fatal("refresh token not stored as its hash")
	}
	user, dev := strconv.FormatInt(users[0].ID, 10), strconv.FormatInt(devices[0].ID, 10)
	want := []string{"sign_in user:" + user + " user:" + user + " ok", "enroll user:" + user + " device:" + dev + " ok"}
	if got := auditActions(t, h.store); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("audit %q, want %q", got, want)
	}
	// The channel stays open for nothing else; logs carry no token or claim.
	c.ws.CloseNow()
	for _, secret := range []string{e.RefreshToken, "001234.abc", "example.com", "eyJ"} {
		if strings.Contains(h.logs.String(), secret) {
			t.Fatalf("log carries %q:\n%s", secret, h.logs.String())
		}
	}
}

// A known identity with a new key gets a new pending device for that user;
// approval of the user carries over only when both are approved.
func TestEnrollKnownIdentityNewKey(t *testing.T) {
	ctx := context.Background()
	h := newAccountsHarness(t, nil)
	first, second := newDevice(t), newDevice(t)
	enrolled(t, reply(h.enroll("sub", first)), "pending")
	users, _ := h.store.Users(ctx)
	admin := accounts.AdminActor("test")
	devices, _ := h.store.Devices(ctx, users[0].ID)
	_ = h.store.SetUserState(ctx, users[0].ID, accounts.UserApproved, admin)
	_ = h.store.SetDeviceState(ctx, devices[0].ID, accounts.DeviceApproved, admin)

	enrolled(t, reply(h.enroll("sub", second)), "pending")
	users, _ = h.store.Users(ctx)
	devices, _ = h.store.Devices(ctx, users[0].ID)
	if len(users) != 1 || len(devices) != 2 || devices[1].State != accounts.DevicePending || users[0].State != accounts.UserApproved {
		t.Fatalf("%+v %+v", users, devices)
	}
	// Enrolling again with the approved key restarts its refresh lineage and
	// reports approved.
	e := enrolled(t, reply(h.enroll("sub", first)), "approved")
	again, _ := h.store.Device(ctx, devices[0].ID)
	hash := accounts.HashToken(e.RefreshToken)
	if !bytes.Equal(again.RefreshHash, hash[:]) || again.PreviousRefreshHash != nil {
		t.Fatal("re-enrollment must issue a new lineage")
	}
	// The key is bound to its user: another identity cannot claim it.
	expectError(t, reply(h.enroll("someone-else", first)), 1, CodeUnauthorized)
}

func reply(_ *testClient, m Message) Message { return m }

// A rejected user gets state rejected, no refresh token and no device, and
// stays rejected.
func TestEnrollRejectedUser(t *testing.T) {
	ctx := context.Background()
	h := newAccountsHarness(t, nil)
	user, _, _ := h.store.EnsureUser(ctx, "apple", "sub", "")
	_ = h.store.SetUserState(ctx, user.ID, accounts.UserRejected, accounts.AdminActor("test"))
	for range 2 {
		e := enrolled(t, reply(h.enroll("sub", newDevice(t))), "rejected")
		if e.RefreshToken != "" {
			t.Fatal("rejected user got a refresh token")
		}
	}
	got, _ := h.store.User(ctx, user.ID)
	devices, _ := h.store.Devices(ctx, user.ID)
	if got.State != accounts.UserRejected || len(devices) != 0 {
		t.Fatalf("%+v %+v", got, devices)
	}
	id := strconv.FormatInt(user.ID, 10)
	if got := auditActions(t, h.store); got[len(got)-1] != "enroll user:"+id+" user:"+id+" not_approved" {
		t.Fatal(got)
	}
	// A revoked user is told so and the channel closes.
	_ = h.store.SetUserState(ctx, user.ID, accounts.UserApproved, accounts.AdminActor("test"))
	_ = h.store.SetUserState(ctx, user.ID, accounts.UserRevoked, accounts.AdminActor("test"))
	c, m := h.enroll("sub", newDevice(t))
	expectError(t, m, 1, CodeRevoked)
	if status := c.closed(); status != websocket.StatusNormalClosure {
		t.Fatal(status)
	}
}

// The P-256 signature over "localflow-v1-enroll" ‖ binding is required.
func TestEnrollSignature(t *testing.T) {
	ctx := context.Background()
	h := newAccountsHarness(t, nil)
	d, other := newDevice(t), newDevice(t)
	for name, sign := range map[string]func(binding []byte) []byte{
		"another channel's binding": func([]byte) []byte { return d.sign(t, []byte(EnrollSignatureLabel), make([]byte, 32)) },
		"refresh label":             func(b []byte) []byte { return d.sign(t, []byte(RefreshSignatureLabel), b) },
		"another key":               func(b []byte) []byte { return other.sign(t, []byte(EnrollSignatureLabel), b) },
		"not DER":                   func([]byte) []byte { return bytes.Repeat([]byte{1}, 64) },
	} {
		c, first := h.hello(PurposeEnroll, "")
		if first.MessageType() != "ready" {
			t.Fatal(first)
		}
		binding := c.channel.Binding()
		c.send(Enroll{Op: 1, Provider: "apple", IDToken: h.appleToken("sub", binding), DeviceName: "Mac",
			DeviceKey: d.public, Signature: sign(binding)})
		expectError(t, c.recv(), 1, CodeUnauthorized)
		c.ws.CloseNow()
		h.clock.Advance(AccountHelloWindow) // stay under the hello rate limit
		_ = name
	}
	if users, _ := h.store.Users(ctx); len(users) != 0 {
		t.Fatal("a refused enrollment created a user")
	}
	if got := auditActions(t, h.store); len(got) == 0 || got[0] != "sign_in system  unauthorized" {
		t.Fatal(got)
	}
}

// The ID token is verified against the channel binding and the provider
// configuration.
func TestEnrollIDToken(t *testing.T) {
	ctx := context.Background()
	h := newAccountsHarness(t, nil)
	d := newDevice(t)
	now := h.clock.Now().Unix()
	for name, token := range map[string]func(binding []byte) (string, string){
		"nonce of another channel": func([]byte) (string, string) { return "apple", h.appleToken("sub", make([]byte, 32)) },
		"google without client ID": func(b []byte) (string, string) {
			return "google", oidctest.Mint(t, nil, map[string]any{"iss": "https://accounts.google.com", "aud": "x", "sub": "g",
				"iat": now, "exp": now + 600, "nonce": oidctest.GoogleNonce(b), "email_verified": true})
		},
		"expired": func(b []byte) (string, string) {
			return "apple", oidctest.Mint(t, nil, map[string]any{"iss": oidc.AppleIssuer, "aud": testAudience, "sub": "s",
				"iat": now - 7200, "exp": now - 3600, "nonce": oidctest.AppleNonce(b)})
		},
	} {
		c, _ := h.hello(PurposeEnroll, "")
		binding := c.channel.Binding()
		provider, idToken := token(binding)
		c.send(Enroll{Op: 1, Provider: provider, IDToken: idToken, DeviceName: "Mac", DeviceKey: d.public,
			Signature: d.sign(t, []byte(EnrollSignatureLabel), binding)})
		m := c.recv()
		if e, ok := m.(ErrorMessage); !ok || e.Code != CodeUnauthorized || e.Op != 1 {
			t.Errorf("%s: %#v", name, m)
		}
		c.ws.CloseNow()
		h.clock.Advance(AccountHelloWindow)
	}
	if users, _ := h.store.Users(ctx); len(users) != 0 {
		t.Fatal("a refused enrollment created a user")
	}
}

// enroll is accepted only within 5 minutes of ready.
func TestEnrollWithinFiveMinutesOfReady(t *testing.T) {
	h := newAccountsHarness(t, nil)
	c, _ := h.hello(PurposeEnroll, "")
	h.clock.waitTimer(t, EnrollIdleTimeout)
	h.clock.Advance(EnrollIdleTimeout - time.Second)
	enrolled(t, h.sendEnroll(c, 1, "sub", newDevice(t)), "pending")

	// The idle timer closes a channel that never enrolls.
	c, _ = h.hello(PurposeEnroll, "")
	h.clock.waitTimer(t, EnrollIdleTimeout)
	h.clock.Advance(EnrollIdleTimeout)
	if status := c.closed(); status != websocket.StatusNormalClosure {
		t.Fatal(status)
	}

	// After a first failed attempt the channel idles 30 s, but a second
	// enroll past 5 minutes from ready is still refused.
	h.clock.Advance(AccountHelloWindow)
	c, _ = h.hello(PurposeEnroll, "")
	h.clock.waitTimer(t, EnrollIdleTimeout)
	h.clock.Advance(EnrollIdleTimeout - 10*time.Second)
	d := newDevice(t)
	binding := c.channel.Binding()
	c.send(Enroll{Op: 1, Provider: "apple", IDToken: h.appleToken("late", binding), DeviceName: "Mac",
		DeviceKey: d.public, Signature: d.sign(t, []byte("wrong"), binding)})
	expectError(t, c.recv(), 1, CodeUnauthorized)
	h.clock.Advance(20 * time.Second)
	expectError(t, h.sendEnroll(c, 2, "late", d), 2, CodeUnauthorized)
	users, _ := h.store.Users(context.Background())
	for _, u := range users {
		if u.Subject == "late" {
			t.Fatal("late enrollment accepted")
		}
	}
}

// 100 pending users: a new identity gets busy and a rate_limited audit row;
// a known identity still enrolls.
func TestEnrollPendingCap(t *testing.T) {
	ctx := context.Background()
	h := newAccountsHarness(t, nil)
	for i := range accounts.MaxPendingUsers {
		if _, _, err := h.store.EnsureUser(ctx, "apple", "pending-"+strconv.Itoa(i), ""); err != nil {
			t.Fatal(err)
		}
	}
	expectError(t, reply(h.enroll("newcomer", newDevice(t))), 1, CodeBusy)
	if got := auditActions(t, h.store); got[len(got)-1] != "rate_limited system  busy" {
		t.Fatal(got)
	}
	enrolled(t, reply(h.enroll("pending-7", newDevice(t))), "pending")
}

// More than 10 enroll or refresh hellos per minute, server-wide, are busy;
// session hellos do not count.
func TestAccountHelloRateLimit(t *testing.T) {
	h := newAccountsHarness(t, nil)
	for i := range MaxAccountHellos {
		purpose := PurposeEnroll
		if i%2 == 1 {
			purpose = PurposeRefresh
		}
		c, first := h.hello(purpose, "")
		if first.MessageType() != "ready" {
			t.Fatalf("hello %d: %#v", i, first)
		}
		c.ws.CloseNow()
	}
	for _, purpose := range []Purpose{PurposeEnroll, PurposeRefresh} {
		c, first := h.hello(purpose, "")
		expectError(t, first, 0, CodeBusy)
		if status := c.closed(); status != websocket.StatusNormalClosure {
			t.Fatal(status)
		}
	}
	_, _, token := h.approved("session", 1)
	if _, first := h.hello(PurposeSession, token); first.MessageType() != "ready" {
		t.Fatalf("session hello limited: %#v", first)
	}
	h.clock.Advance(AccountHelloWindow - time.Millisecond)
	_, first := h.hello(PurposeEnroll, "")
	expectError(t, first, 0, CodeBusy)
	h.clock.Advance(time.Millisecond)
	if _, first := h.hello(PurposeEnroll, ""); first.MessageType() != "ready" {
		t.Fatalf("after a minute: %#v", first)
	}
}
