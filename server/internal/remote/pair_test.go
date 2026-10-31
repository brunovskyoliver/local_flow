package remote

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"localflow/server/internal/accounts"
)

// newToken issues a token; userID 0 targets a new user.
func (h *accountsHarness) newToken(userID int64, lifetime time.Duration) (string, accounts.PairingToken) {
	h.t.Helper()
	value, row, err := h.store.CreatePairingToken(context.Background(), h.identity.PublicKey(), "Anna", userID, lifetime, accounts.AdminActor("oliver"))
	if err != nil {
		h.t.Fatal(err)
	}
	return value, row
}

// sendPair opens an enroll channel and sends one correctly signed pair.
func (h *accountsHarness) sendPair(token string, d *device) (*testClient, Message) {
	h.t.Helper()
	c, first := h.hello(PurposeEnroll, "")
	if first.MessageType() != "ready" {
		h.t.Fatalf("%#v", first)
	}
	c.send(Pair{Op: 1, PairingToken: token, DeviceName: "Anna's iPhone", DeviceKey: d.public,
		Signature: d.sign(h.t, []byte(PairSignatureLabel), c.channel.Binding())})
	return c, c.recv()
}

func (h *accountsHarness) tokenState(id int64) accounts.PairingState {
	h.t.Helper()
	tokens, err := h.store.PairingTokens(context.Background())
	if err != nil {
		h.t.Fatal(err)
	}
	for _, token := range tokens {
		if token.ID == id {
			return token.State
		}
	}
	h.t.Fatalf("no token %d", id)
	return ""
}

// The whole path: a token becomes an approved device whose refresh token opens
// a session straight away, without waiting for the snapshot poll.
func TestPairApprovesAndRefreshes(t *testing.T) {
	ctx := context.Background()
	h := newAccountsHarness(t, nil)
	value, row := h.newToken(0, accounts.DefaultPairingLifetime)
	d := newDevice(t)
	_, reply := h.sendPair(value, d)
	e := enrolled(t, reply, "approved")
	if h.tokenState(row.ID) != accounts.PairingRedeemed {
		t.Fatal("token not redeemed")
	}
	users, _ := h.store.Users(ctx)
	if len(users) != 1 || users[0].Provider != "token" || users[0].State != accounts.UserApproved || users[0].Display != "Anna" {
		t.Fatalf("%+v", users)
	}
	devices, _ := h.store.Devices(ctx, users[0].ID)
	if len(devices) != 1 || devices[0].State != accounts.DeviceApproved || devices[0].Name != "Anna's iPhone" {
		t.Fatalf("%+v", devices)
	}

	h.clock.Advance(AccountHelloWindow)
	c, _ := h.hello(PurposeRefresh, "")
	digest := sha256Of(e.RefreshToken)
	c.send(Refresh{Op: 1, RefreshToken: e.RefreshToken, Signature: d.sign(t, []byte(RefreshSignatureLabel), c.channel.Binding(), digest)})
	tokens, ok := c.recv().(Tokens)
	if !ok {
		t.Fatal("refresh after pair refused")
	}
	if _, first := h.hello(PurposeSession, tokens.AccessToken); first.MessageType() != "ready" {
		t.Fatalf("session after pair: %#v", first)
	}

	logs := h.logs.String()
	if strings.Contains(logs, value) || strings.Contains(logs, "lfp_") || !strings.Contains(logs, "op=pair") {
		t.Fatalf("pair log: %s", logs)
	}
	for _, line := range auditActions(t, h.store) {
		if strings.Contains(line, "lfp_") {
			t.Fatal(line)
		}
	}
	want := "pair device:" + strconv.FormatInt(devices[0].ID, 10) + " token:" + strconv.FormatInt(row.ID, 10) + " ok"
	if !slices.Contains(auditActions(t, h.store), want) {
		t.Fatalf("%q missing from %v", want, auditActions(t, h.store))
	}
}

// Bad signature: unauthorized, the token stays live, one audit row.
func TestPairBadSignature(t *testing.T) {
	h := newAccountsHarness(t, nil)
	value, row := h.newToken(0, accounts.DefaultPairingLifetime)
	d, other := newDevice(t), newDevice(t)
	c, _ := h.hello(PurposeEnroll, "")
	c.send(Pair{Op: 1, PairingToken: value, DeviceName: "Phone", DeviceKey: d.public,
		Signature: other.sign(t, []byte(PairSignatureLabel), c.channel.Binding())})
	expectError(t, c.recv(), 1, CodeUnauthorized)
	if h.tokenState(row.ID) != accounts.PairingLive {
		t.Fatal("token spent by a bad signature")
	}
	if got := auditActions(t, h.store); got[len(got)-1] != "pair system  unauthorized" {
		t.Fatal(got)
	}

	// A signature with the enroll label does not pass as a pair signature.
	c.send(Pair{Op: 2, PairingToken: value, DeviceName: "Phone", DeviceKey: d.public,
		Signature: d.sign(t, []byte(EnrollSignatureLabel), c.channel.Binding())})
	expectError(t, c.recv(), 2, CodeUnauthorized)
}

// Pair is refused more than 5 minutes after ready, like enroll: a failed first
// attempt keeps the channel idling past that point.
func TestPairAfterTheEnrollWindow(t *testing.T) {
	h := newAccountsHarness(t, nil)
	value, row := h.newToken(0, accounts.DefaultPairingLifetime)
	d := newDevice(t)
	c, _ := h.hello(PurposeEnroll, "")
	h.clock.waitTimer(t, EnrollIdleTimeout)
	h.clock.Advance(EnrollIdleTimeout - 10*time.Second)
	binding := c.channel.Binding()
	c.send(Pair{Op: 1, PairingToken: value, DeviceName: "Phone", DeviceKey: d.public, Signature: d.sign(t, []byte("wrong"), binding)})
	expectError(t, c.recv(), 1, CodeUnauthorized)
	h.clock.Advance(20 * time.Second)
	c.send(Pair{Op: 2, PairingToken: value, DeviceName: "Phone", DeviceKey: d.public, Signature: d.sign(t, []byte(PairSignatureLabel), binding)})
	expectError(t, c.recv(), 2, CodeUnauthorized)
	if h.tokenState(row.ID) != accounts.PairingLive {
		t.Fatal("token spent late")
	}
}

// Unknown, expired, used by another key and revoked tokens get one answer, and
// the store's audit row is the only one.
func TestPairTokenInvalid(t *testing.T) {
	h := newAccountsHarness(t, nil)
	expect := func(name, token string) {
		t.Helper()
		before := len(auditActions(t, h.store))
		c, reply := h.sendPair(token, newDevice(t))
		expectError(t, reply, 1, CodePairingTokenInvalid)
		c.ws.CloseNow()
		got := auditActions(t, h.store)
		if len(got) != before+1 || !strings.HasSuffix(got[len(got)-1], "pairing_token_invalid") {
			t.Fatalf("%s: audit %v", name, got)
		}
		h.clock.Advance(AccountHelloWindow)
	}

	unknown, _, err := accounts.NewPairingToken(h.identity.PublicKey())
	if err != nil {
		t.Fatal(err)
	}
	expect("unknown", unknown)

	expired, _ := h.newToken(0, time.Hour)
	h.clock.Advance(time.Hour + time.Second)
	expect("expired", expired)

	used, _ := h.newToken(0, accounts.DefaultPairingLifetime)
	_, reply := h.sendPair(used, newDevice(t))
	enrolled(t, reply, "approved")
	expect("used by another key", used)

	revoked, row := h.newToken(0, accounts.DefaultPairingLifetime)
	if err := h.store.RevokePairingToken(context.Background(), row.ID, accounts.AdminActor("oliver")); err != nil {
		t.Fatal(err)
	}
	expect("revoked", revoked)
}

// The reply can be lost: the redeeming key retries and gets a working lineage.
func TestPairSameKeyRetry(t *testing.T) {
	h := newAccountsHarness(t, nil)
	value, _ := h.newToken(0, accounts.DefaultPairingLifetime)
	d := newDevice(t)
	_, first := h.sendPair(value, d)
	a := enrolled(t, first, "approved")
	_, second := h.sendPair(value, d)
	b := enrolled(t, second, "approved")
	if a.RefreshToken == b.RefreshToken {
		t.Fatal("same refresh token twice")
	}
	users, _ := h.store.Users(context.Background())
	if len(users) != 1 {
		t.Fatalf("%+v", users)
	}
}

// A key enrolled to another user: unauthorized, token unspent.
func TestPairKeyOfAnotherUser(t *testing.T) {
	h := newAccountsHarness(t, nil)
	d := newDevice(t)
	_, reply := h.enroll("someone-else", d)
	enrolled(t, reply, "pending")
	value, row := h.newToken(0, accounts.DefaultPairingLifetime)
	_, answer := h.sendPair(value, d)
	expectError(t, answer, 1, CodeUnauthorized)
	if h.tokenState(row.ID) != accounts.PairingLive {
		t.Fatal("token spent")
	}
}

// A revoked device or a revoked target user: revoked, token unspent, channel closed.
func TestPairRevoked(t *testing.T) {
	ctx := context.Background()
	h := newAccountsHarness(t, nil)
	admin := accounts.AdminActor("oliver")
	d := newDevice(t)
	value, _ := h.newToken(0, accounts.DefaultPairingLifetime)
	_, reply := h.sendPair(value, d)
	enrolled(t, reply, "approved")
	users, _ := h.store.Users(ctx)
	devices, _ := h.store.Devices(ctx, users[0].ID)

	// The same user's device, revoked, presents a new token for that user.
	next, nextRow := h.newToken(users[0].ID, accounts.DefaultPairingLifetime)
	if err := h.store.SetDeviceState(ctx, devices[0].ID, accounts.DeviceRevoked, admin); err != nil {
		t.Fatal(err)
	}
	c, answer := h.sendPair(next, d)
	expectError(t, answer, 1, CodeRevoked)
	c.closed()
	if h.tokenState(nextRow.ID) != accounts.PairingLive {
		t.Fatal("token spent by a revoked device")
	}

	// A new device with a token whose target user was revoked afterwards.
	if err := h.store.SetUserState(ctx, users[0].ID, accounts.UserRevoked, admin); err != nil {
		t.Fatal(err)
	}
	h.clock.Advance(AccountHelloWindow)
	c, answer = h.sendPair(next, newDevice(t))
	expectError(t, answer, 1, CodeRevoked)
	c.closed()
	if h.tokenState(nextRow.ID) != accounts.PairingLive {
		t.Fatal("token spent for a revoked user")
	}
}

// Too many hellos are busy, before any pair message.
func TestPairHelloLimit(t *testing.T) {
	h := newAccountsHarness(t, nil)
	value, row := h.newToken(0, accounts.DefaultPairingLifetime)
	for range MaxAccountHellos {
		c, _ := h.hello(PurposeEnroll, "")
		c.ws.CloseNow()
	}
	_, first := h.hello(PurposeEnroll, "")
	expectError(t, first, 0, CodeBusy)
	if h.tokenState(row.ID) != accounts.PairingLive || value == "" {
		t.Fatal("token spent")
	}
}

// recordingConn keeps every byte a reverse proxy passes to the listener and back.
type recordingConn struct {
	net.Conn
	seen *lockedBytes
}

type lockedBytes struct {
	sync.Mutex
	bytes.Buffer
}

func (b *lockedBytes) add(p []byte) {
	b.Lock()
	defer b.Unlock()
	b.Write(p)
}

func (b *lockedBytes) snapshot() []byte {
	b.Lock()
	defer b.Unlock()
	return bytes.Clone(b.Bytes())
}

func (c recordingConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.seen.add(p[:n])
	return n, err
}

func (c recordingConn) Write(p []byte) (int, error) {
	c.seen.add(p)
	return c.Conn.Write(p)
}

// US2: one paired device works through a reverse proxy and directly, with the
// same credentials, and the proxy sees only sealed frames: neither the token,
// nor its parts, nor what it was exchanged for.
func TestPairAndUseThroughAReverseProxy(t *testing.T) {
	h := newAccountsHarness(t, nil)
	direct := h.url
	target, err := url.Parse(direct)
	if err != nil {
		t.Fatal(err)
	}
	seen := &lockedBytes{}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = &http.Transport{DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
		conn, err := (&net.Dialer{}).DialContext(ctx, network, addr)
		if err != nil {
			return nil, err
		}
		return recordingConn{conn, seen}, nil
	}}
	front := httptest.NewServer(proxy)
	defer front.Close()

	// Each round names its own client: the earlier channels are still open and count.
	round := 0
	refreshOver := func(address, token string, d *device) Tokens {
		t.Helper()
		h.url = address
		h.clock.Advance(AccountHelloWindow)
		round++
		client := fmt.Sprintf("203.0.113.%d", round)
		c, _ := h.helloFrom(client, PurposeRefresh, "")
		c.send(Refresh{Op: 1, RefreshToken: token, Signature: d.sign(t, []byte(RefreshSignatureLabel), c.channel.Binding(), sha256Of(token))})
		tokens, ok := c.recv().(Tokens)
		if !ok {
			t.Fatalf("refresh over %s refused", address)
		}
		if _, first := h.helloFrom(client, PurposeSession, tokens.AccessToken); first.MessageType() != "ready" {
			t.Fatalf("session over %s: %#v", address, first)
		}
		return tokens
	}

	value, _ := h.newToken(0, accounts.DefaultPairingLifetime)
	d := newDevice(t)
	h.url = front.URL
	_, reply := h.sendPair(value, d)
	first := enrolled(t, reply, "approved")
	second := refreshOver(front.URL, first.RefreshToken, d)
	third := refreshOver(direct, second.RefreshToken, d)
	fourth := refreshOver(front.URL, third.RefreshToken, d)

	observed := seen.snapshot()
	if !bytes.Contains(observed, []byte("GET /v1/remote/channel")) || len(observed) < 4096 {
		t.Fatalf("the recorder saw too little to prove anything: %d bytes", len(observed))
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(value, accounts.PairingPrefix))
	if err != nil {
		t.Fatal(err)
	}
	secrets := map[string][]byte{
		"token": []byte(value), "prefix": []byte(accounts.PairingPrefix),
		"encoded secret": []byte(base64.RawURLEncoding.EncodeToString(raw[32:])), "raw secret": raw[32:],
		"hex secret":    []byte(hex.EncodeToString(raw[32:])),
		"first refresh": []byte(first.RefreshToken), "refresh": []byte(fourth.RefreshToken),
		"access": []byte(fourth.AccessToken),
	}
	for name, secret := range secrets {
		if bytes.Contains(observed, secret) {
			t.Errorf("the proxy saw the %s", name)
		}
	}
}

// pairingVectors is fixtures/remote/pairing-vectors.json; the Swift side is
// PairingTokenTests. Every byte string is hex.
type pairingVectors struct {
	Description     string `json:"description"`
	Label           string `json:"label"`
	Binding         string `json:"binding"`
	SignatureInput  string `json:"signature_input"`
	DevicePublicKey string `json:"device_public_key"`
	Signature       string `json:"signature"`
	ServerPublicKey string `json:"server_public_key"`
	TokenRandom     string `json:"token_random"`
	Token           string `json:"token"`
}

const pairingVectorsPath = "../../../fixtures/remote/pairing-vectors.json"

// generatePairingVectors signs with a throwaway key; ECDSA signatures aren't
// repeatable, so -update rewrites the file and the checks below verify it.
func generatePairingVectors(t *testing.T) {
	d := newDevice(t)
	binding := sha256.Sum256([]byte("localflow pairing vector binding"))
	serverKey := sha256.Sum256([]byte("localflow pairing vector server key"))
	random := sha256.Sum256([]byte("localflow pairing vector token"))
	v := pairingVectors{
		Description:     "Test-only. The bytes a pair message signs and the pairing token encoding, checked from Go (pair_test.go) and Swift (PairingTokenTests).",
		Label:           PairSignatureLabel,
		Binding:         hex.EncodeToString(binding[:]),
		SignatureInput:  hex.EncodeToString(append([]byte(PairSignatureLabel), binding[:]...)),
		DevicePublicKey: hex.EncodeToString(d.public),
		Signature:       hex.EncodeToString(d.sign(t, []byte(PairSignatureLabel), binding[:])),
		ServerPublicKey: hex.EncodeToString(serverKey[:]),
		TokenRandom:     hex.EncodeToString(random[:]),
		Token:           accounts.PairingPrefix + base64.RawURLEncoding.EncodeToString(append(serverKey[:], random[:]...)),
	}
	encoded, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pairingVectorsPath, append(encoded, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestPairingVectors(t *testing.T) {
	if *update {
		generatePairingVectors(t)
	}
	data, err := os.ReadFile(pairingVectorsPath)
	if err != nil {
		t.Fatal(err)
	}
	var v pairingVectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	decode := func(s string) []byte {
		t.Helper()
		b, err := hex.DecodeString(s)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	binding, key, signature := decode(v.Binding), decode(v.DevicePublicKey), decode(v.Signature)
	if v.Label != PairSignatureLabel || !bytes.Equal(decode(v.SignatureInput), append([]byte(PairSignatureLabel), binding...)) {
		t.Fatal("label or signature input changed")
	}
	if !verifyDeviceSignature(key, signature, []byte(PairSignatureLabel), binding) {
		t.Fatal("the server refuses the vector signature")
	}
	if verifyDeviceSignature(key, signature, binding, []byte(PairSignatureLabel)) {
		t.Fatal("binding and label are interchangeable")
	}
	want := accounts.PairingPrefix + base64.RawURLEncoding.EncodeToString(append(decode(v.ServerPublicKey), decode(v.TokenRandom)...))
	if v.Token != want {
		t.Fatalf("token encoding: %q, want %q", v.Token, want)
	}
	// NewPairingToken makes the same shape: the server's key, then 32 random bytes.
	made, _, err := accounts.NewPairingToken(decode(v.ServerPublicKey))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(made, accounts.PairingPrefix))
	if err != nil || len(raw) != 64 || !bytes.Equal(raw[:32], decode(v.ServerPublicKey)) {
		t.Fatalf("%x %v", raw, err)
	}
}

func sha256Of(s string) []byte {
	sum := sha256.Sum256([]byte(s))
	return sum[:]
}
