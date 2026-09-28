package remote

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"localflow/server/internal/accounts"
)

// Session hello authentication (T044): every refusal is a hello error with no
// op that closes the channel, and the channel's user and device come only
// from the token (FR-024).
func TestSessionHelloAuthentication(t *testing.T) {
	ctx := context.Background()
	h := newHarness(t, Operations{})
	admin := accounts.AdminActor("test")

	// A pending user with a pending device, and a pending device of an
	// approved user.
	pendingUser, _, _ := h.store.EnsureUser(ctx, "google", "pending", "")
	pendingKey := bytes.Repeat([]byte{7}, 65)
	pendingKey[0] = 0x04
	pendingUserDevice, _ := h.store.AddDevice(ctx, pendingUser.ID, "Mac", pendingKey)
	pendingUserToken, _, _ := h.store.IssueAccess(ctx, pendingUserDevice.ID)

	approvedUser, approvedDevice, approvedToken := h.approved("approved", 1)
	secondKey := bytes.Repeat([]byte{8}, 65)
	secondKey[0] = 0x04
	pendingDevice, _ := h.store.AddDevice(ctx, approvedUser.ID, "Mac Studio", secondKey)
	pendingDeviceToken, _, _ := h.store.IssueAccess(ctx, pendingDevice.ID)

	// A rejected user whose device is approved.
	rejectedUser, _, _ := h.store.EnsureUser(ctx, "apple", "rejected", "")
	rejectedKey := bytes.Repeat([]byte{9}, 65)
	rejectedKey[0] = 0x04
	rejectedDevice, _ := h.store.AddDevice(ctx, rejectedUser.ID, "Mac", rejectedKey)
	_ = h.store.SetUserState(ctx, rejectedUser.ID, accounts.UserRejected, admin)
	_ = h.store.SetDeviceState(ctx, rejectedDevice.ID, accounts.DeviceApproved, admin)
	rejectedToken, _, _ := h.store.IssueAccess(ctx, rejectedDevice.ID)

	// A revoked device (its access hash is cleared) and a revoked user.
	_, revokedDevice, revokedDeviceToken := h.approved("revoked-device", 2)
	_ = h.store.SetDeviceState(ctx, revokedDevice.ID, accounts.DeviceRevoked, admin)
	revokedUser, _, revokedUserToken := h.approved("revoked-user", 3)
	_ = h.store.SetUserState(ctx, revokedUser.ID, accounts.UserRevoked, admin)
	h.poll()

	for _, tc := range []struct {
		name  string
		token string
		code  ErrorCode
	}{
		{"unknown token", "lfa_" + strings.Repeat("A", 43), CodeUnauthorized},
		{"malformed token", "lfa_short", CodeUnauthorized},
		{"refresh token as access token", "lfr_" + strings.Repeat("A", 43), CodeUnauthorized},
		{"pending user and device", pendingUserToken, CodeNotApproved},
		{"pending device of an approved user", pendingDeviceToken, CodeNotApproved},
		{"rejected user", rejectedToken, CodeNotApproved},
		{"revoked device", revokedDeviceToken, CodeRevoked},
		{"revoked user", revokedUserToken, CodeRevoked},
	} {
		c, first := h.hello(PurposeSession, tc.token)
		e, ok := first.(ErrorMessage)
		if !ok || e.Code != tc.code || e.Op != 0 {
			t.Errorf("%s: %#v, want %s without op", tc.name, first, tc.code)
			continue
		}
		if status := c.closed(); status != websocket.StatusNormalClosure {
			t.Errorf("%s: close status %d", tc.name, status)
		}
	}

	// The approved token authenticates to exactly its own user and device.
	c, first := h.hello(PurposeSession, approvedToken)
	if first.MessageType() != "ready" {
		t.Fatalf("%#v", first)
	}
	conns := h.listener.Registry().Device(approvedDevice.ID)
	if len(conns) != 1 || conns[0].Principal() != (accounts.Principal{UserID: approvedUser.ID, DeviceID: approvedDevice.ID}) {
		t.Fatal("principal must come from the token")
	}
	c.ws.CloseNow()

	// Expiry is by the server clock: valid one millisecond before, refused at
	// the expiry instant.
	h.clock.Advance(accounts.AccessLifetime - time.Millisecond)
	if _, first := h.hello(PurposeSession, approvedToken); first.MessageType() != "ready" {
		t.Fatalf("before expiry: %#v", first)
	}
	h.clock.Advance(time.Millisecond)
	c, first = h.hello(PurposeSession, approvedToken)
	expectError(t, first, 0, CodeTokenExpired)
	if status := c.closed(); status != websocket.StatusNormalClosure {
		t.Fatal(status)
	}
}

// A hello cannot name a user or device: the only identity input is the
// token. Extra fields are refused as invalid_message before authentication.
func TestSessionHelloIgnoresClaimedIdentity(t *testing.T) {
	h := newHarness(t, Operations{})
	_, _, token := h.approved("a", 1)
	c := h.dial()
	key := newKey(t)
	c.channel, _ = NewClient(h.identity.PublicKey(), key)
	plaintext := `{"schema_version":1,"type":"hello","reply_key":"` + b64(key.PublicKey().Bytes()) +
		`","purpose":"session","access_token":"` + token + `","user_id":2,"device_id":2}`
	sealed, _ := c.channel.Hello([]byte(plaintext))
	if err := c.ws.Write(context.Background(), websocket.MessageBinary, sealed); err != nil {
		t.Fatal(err)
	}
	expectError(t, c.recv(), 0, CodeInvalidMessage)
	if status := c.closed(); status != websocket.StatusNormalClosure {
		t.Fatal(status)
	}
}

// A device approved again after revocation does not revive its old token:
// the revoked token is then simply unknown.
func TestRevokedTokenAfterReapproval(t *testing.T) {
	ctx := context.Background()
	h := newHarness(t, Operations{})
	_, device, token := h.approved("a", 1)
	admin := accounts.AdminActor("test")
	_ = h.store.SetDeviceState(ctx, device.ID, accounts.DeviceRevoked, admin)
	h.poll()
	_, first := h.hello(PurposeSession, token)
	expectError(t, first, 0, CodeRevoked)
	_ = h.store.SetDeviceState(ctx, device.ID, accounts.DeviceApproved, admin)
	h.poll()
	_, first = h.hello(PurposeSession, token)
	expectError(t, first, 0, CodeUnauthorized)
}
