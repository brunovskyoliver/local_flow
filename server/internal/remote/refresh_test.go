package remote

import (
	"bytes"
	"context"
	"crypto/sha256"
	"testing"

	"github.com/coder/websocket"

	"localflow/server/internal/accounts"
)

// enrolledDevice enrolls d for subject and returns its device row and
// refresh token; approve approves the user and the device.
func (h *accountsHarness) enrolledDevice(subject string, d *device, approve bool) (accounts.Device, string) {
	h.t.Helper()
	ctx := context.Background()
	c, m := h.enroll(subject, d)
	c.ws.CloseNow()
	e, ok := m.(Enrolled)
	if !ok {
		h.t.Fatalf("%#v", m)
	}
	row, err := h.store.DeviceByKey(ctx, d.public)
	if err != nil {
		h.t.Fatal(err)
	}
	if approve {
		admin := accounts.AdminActor("test")
		_ = h.store.SetUserState(ctx, row.UserID, accounts.UserApproved, admin)
		_ = h.store.SetDeviceState(ctx, row.ID, accounts.DeviceApproved, admin)
		h.poll()
	}
	return row, e.RefreshToken
}

// refresh opens a refresh channel and sends one refresh signed by d.
func (h *accountsHarness) refresh(token string, d *device) (*testClient, Message) {
	h.t.Helper()
	c, first := h.hello(PurposeRefresh, "")
	if first.MessageType() != "ready" {
		h.t.Fatalf("%#v", first)
	}
	h.clock.Advance(AccountHelloWindow / 10) // keep under the hello rate limit
	binding := c.channel.Binding()
	hash := sha256.Sum256([]byte(token))
	c.send(Refresh{Op: 1, RefreshToken: token, Signature: d.sign(h.t, []byte(RefreshSignatureLabel), binding, hash[:])})
	return c, c.recv()
}

func TestRefreshIssuesAndRotates(t *testing.T) {
	h := newAccountsHarness(t, nil)
	d := newDevice(t)
	row, refresh := h.enrolledDevice("sub", d, true)
	_, m := h.refresh(refresh, d)
	tokens, ok := m.(Tokens)
	if !ok || tokens.Op != 1 || tokens.ExpiresIn != 900 || tokens.RefreshToken == refresh {
		t.Fatalf("%#v", m)
	}
	got, _ := h.store.Device(context.Background(), row.ID)
	oldHash, newHash := accounts.HashToken(refresh), accounts.HashToken(tokens.RefreshToken)
	if !bytes.Equal(got.RefreshHash, newHash[:]) || !bytes.Equal(got.PreviousRefreshHash, oldHash[:]) {
		t.Fatal("refresh token not rotated")
	}
	// The new access token opens a session at once, without waiting for the
	// 250 ms snapshot poll.
	if _, first := h.hello(PurposeSession, tokens.AccessToken); first.MessageType() != "ready" {
		t.Fatalf("%#v", first)
	}
	// The rotated token refreshes again.
	if _, m := h.refresh(tokens.RefreshToken, d); m.MessageType() != "tokens" {
		t.Fatalf("%#v", m)
	}
}

// Presenting the replaced token without the device's signature revokes the
// device and closes the channel.
func TestRefreshReuseRevokesDevice(t *testing.T) {
	ctx := context.Background()
	h := newAccountsHarness(t, nil)
	d := newDevice(t)
	row, refresh := h.enrolledDevice("sub", d, true)
	_, m := h.refresh(refresh, d)
	tokens := m.(Tokens)
	session, first := h.hello(PurposeSession, tokens.AccessToken)
	if first.MessageType() != "ready" {
		t.Fatal(first)
	}
	c, m := h.refresh(refresh, newDevice(t))
	expectError(t, m, 1, CodeRevoked)
	if status := c.closed(); status != websocket.StatusNormalClosure {
		t.Fatal(status)
	}
	if got, _ := h.store.Device(ctx, row.ID); got.State != accounts.DeviceRevoked {
		t.Fatal(got.State)
	}
	// The device's open session is closed with revoked, and the current
	// token no longer refreshes.
	expectError(t, session.recv(), 0, CodeRevoked)
	// Later presentations of either token of the lineage answer revoked.
	for _, token := range []string{tokens.RefreshToken, refresh} {
		c, m = h.refresh(token, d)
		expectError(t, m, 1, CodeRevoked)
		if status := c.closed(); status != websocket.StatusNormalClosure {
			t.Fatal(status)
		}
	}
	_, first = h.hello(PurposeSession, tokens.AccessToken)
	expectError(t, first, 0, CodeRevoked)
}

// not_approved leaves the refresh token valid and unrotated.
func TestRefreshNotApproved(t *testing.T) {
	ctx := context.Background()
	h := newAccountsHarness(t, nil)
	d := newDevice(t)
	row, refresh := h.enrolledDevice("sub", d, false)
	c, m := h.refresh(refresh, d)
	expectError(t, m, 1, CodeNotApproved)
	got, _ := h.store.Device(ctx, row.ID)
	hash := accounts.HashToken(refresh)
	if !bytes.Equal(got.RefreshHash, hash[:]) || got.PreviousRefreshHash != nil || got.AccessHash != nil {
		t.Fatal("not_approved must not rotate or issue")
	}
	// The channel stays usable: approval then succeeds with the same token.
	admin := accounts.AdminActor("test")
	_ = h.store.SetUserState(ctx, row.UserID, accounts.UserApproved, admin)
	_ = h.store.SetDeviceState(ctx, row.ID, accounts.DeviceApproved, admin)
	h.poll()
	binding := c.channel.Binding()
	sum := sha256.Sum256([]byte(refresh))
	c.send(Refresh{Op: 2, RefreshToken: refresh, Signature: d.sign(t, []byte(RefreshSignatureLabel), binding, sum[:])})
	if m := c.recv(); m.MessageType() != "tokens" {
		t.Fatalf("%#v", m)
	}
}

// The signature binds the refresh to this channel, this token and this
// device's key.
func TestRefreshSignature(t *testing.T) {
	ctx := context.Background()
	h := newAccountsHarness(t, nil)
	d, other := newDevice(t), newDevice(t)
	row, refresh := h.enrolledDevice("sub", d, true)
	hash := sha256.Sum256([]byte(refresh))
	otherChannel, _ := h.hello(PurposeRefresh, "")
	for name, sign := range map[string]func(binding []byte) []byte{
		"another channel's binding": func([]byte) []byte {
			return d.sign(t, []byte(RefreshSignatureLabel), otherChannel.channel.Binding(), hash[:])
		},
		"enroll label":     func(b []byte) []byte { return d.sign(t, []byte(EnrollSignatureLabel), b, hash[:]) },
		"another token":    func(b []byte) []byte { return d.sign(t, []byte(RefreshSignatureLabel), b, make([]byte, 32)) },
		"another key":      func(b []byte) []byte { return other.sign(t, []byte(RefreshSignatureLabel), b, hash[:]) },
		"token not hashed": func(b []byte) []byte { return d.sign(t, []byte(RefreshSignatureLabel), b, []byte(refresh)) },
	} {
		c, _ := h.hello(PurposeRefresh, "")
		c.send(Refresh{Op: 1, RefreshToken: refresh, Signature: sign(c.channel.Binding())})
		m := c.recv()
		if e, ok := m.(ErrorMessage); !ok || e.Code != CodeUnauthorized || e.Op != 1 {
			t.Errorf("%s: %#v", name, m)
		}
		c.ws.CloseNow()
		h.clock.Advance(AccountHelloWindow)
	}
	got, _ := h.store.Device(ctx, row.ID)
	if !bytes.Equal(got.RefreshHash, hash[:]) || got.State != accounts.DeviceApproved {
		t.Fatal("a refused signature must not rotate or revoke")
	}
	// An unknown token is unauthorized too.
	_, m := h.refresh("lfr_"+string(bytes.Repeat([]byte("A"), 43)), d)
	expectError(t, m, 1, CodeUnauthorized)
}

// After an admin revocation of the device or its user, the device's current
// and previous refresh tokens answer revoked; after re-approval of a revoked
// device the old tokens are unknown.
func TestRefreshAfterAdminRevoke(t *testing.T) {
	ctx := context.Background()
	admin := accounts.AdminActor("test")
	for _, byUser := range []bool{false, true} {
		h := newAccountsHarness(t, nil)
		d := newDevice(t)
		row, previous := h.enrolledDevice("sub", d, true)
		_, m := h.refresh(previous, d)
		current := m.(Tokens).RefreshToken
		if byUser {
			_ = h.store.SetUserState(ctx, row.UserID, accounts.UserRevoked, admin)
		} else {
			_ = h.store.SetDeviceState(ctx, row.ID, accounts.DeviceRevoked, admin)
		}
		for _, token := range []string{current, previous} {
			_, m := h.refresh(token, d)
			expectError(t, m, 1, CodeRevoked)
		}
		if byUser {
			continue
		}
		_ = h.store.SetDeviceState(ctx, row.ID, accounts.DeviceApproved, admin)
		for _, token := range []string{current, previous} {
			_, m := h.refresh(token, d)
			expectError(t, m, 1, CodeUnauthorized)
		}
	}
}

// The device presenting its previous token with its own signature (the reply
// to its last refresh never arrived) gets a new pair and stays approved.
func TestRefreshSignedReplayReissues(t *testing.T) {
	ctx := context.Background()
	h := newAccountsHarness(t, nil)
	d := newDevice(t)
	row, refresh := h.enrolledDevice("sub", d, true)
	if _, m := h.refresh(refresh, d); m.MessageType() != "tokens" {
		t.Fatalf("%#v", m)
	}
	_, m := h.refresh(refresh, d)
	tokens, ok := m.(Tokens)
	if !ok {
		t.Fatalf("%#v", m)
	}
	if got, _ := h.store.Device(ctx, row.ID); got.State != accounts.DeviceApproved {
		t.Fatal(got.State)
	}
	if _, first := h.hello(PurposeSession, tokens.AccessToken); first.MessageType() != "ready" {
		t.Fatalf("%#v", first)
	}
}
