package accounts

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestNewToken(t *testing.T) {
	for _, prefix := range []string{AccessPrefix, RefreshPrefix} {
		token, hash, err := NewToken(prefix)
		if err != nil || !strings.HasPrefix(token, prefix) || len(token) != len(prefix)+43 {
			t.Fatal(token, err)
		}
		raw, err := base64.RawURLEncoding.Strict().DecodeString(strings.TrimPrefix(token, prefix))
		if err != nil || len(raw) != 32 {
			t.Fatal("32 random bytes, base64url without padding", err)
		}
		if hash != sha256.Sum256([]byte(token)) || hash != HashToken(token) {
			t.Fatal("hash is SHA-256 of the token string")
		}
		other, _, _ := NewToken(prefix)
		if other == token {
			t.Fatal("tokens repeat")
		}
	}
	if _, _, err := NewToken("xyz_"); err == nil {
		t.Fatal("unknown prefix accepted")
	}
}

// approvedDevice returns an approved device of an approved user.
func approvedDevice(t *testing.T, store *Store) Device {
	t.Helper()
	user, _, _ := store.EnsureUser(ctx, "apple", "sub", "")
	device, _ := store.AddDevice(ctx, user.ID, "Mac", deviceKey(1))
	if err := store.SetUserState(ctx, user.ID, UserApproved, AdminActor("oliver")); err != nil {
		t.Fatal(err)
	}
	if err := store.SetDeviceState(ctx, device.ID, DeviceApproved, AdminActor("oliver")); err != nil {
		t.Fatal(err)
	}
	return device
}

// rowBytes concatenates every column of the device row as stored.
func rowBytes(t *testing.T, store *Store, id int64) []byte {
	t.Helper()
	var name, state string
	var key, refresh, previous, access []byte
	var a, b, c, d, e, f any
	if err := store.db.QueryRow(`SELECT name, public_key, state, refresh_hash, previous_refresh_hash, refresh_expires_at, access_hash, access_expires_at, enrolled_at, last_seen_at, changed_at, user_id FROM devices WHERE id = ?`, id).
		Scan(&name, &key, &state, &refresh, &previous, &a, &access, &b, &c, &d, &e, &f); err != nil {
		t.Fatal(err)
	}
	return bytes.Join([][]byte{[]byte(name), key, []byte(state), refresh, previous, access}, nil)
}

func TestIssueStoresOnlyHashes(t *testing.T) {
	store, clock, _ := openStore(t)
	device := approvedDevice(t, store)
	refresh, refreshExpires, err := store.IssueRefresh(ctx, device.ID)
	if err != nil || !refreshExpires.Equal(clock.Now().Add(30*24*time.Hour)) {
		t.Fatal(refreshExpires, err)
	}
	access, accessExpires, err := store.IssueAccess(ctx, device.ID)
	if err != nil || !accessExpires.Equal(clock.Now().Add(15*time.Minute)) {
		t.Fatal(accessExpires, err)
	}
	got, _ := store.Device(ctx, device.ID)
	refreshHash, accessHash := HashToken(refresh), HashToken(access)
	if !bytes.Equal(got.RefreshHash, refreshHash[:]) || !bytes.Equal(got.AccessHash, accessHash[:]) || got.PreviousRefreshHash != nil {
		t.Fatalf("%+v", got)
	}
	row := rowBytes(t, store, device.ID)
	for _, token := range []string{refresh, access} {
		raw, _ := base64.RawURLEncoding.DecodeString(token[4:])
		if bytes.Contains(row, []byte(token)) || bytes.Contains(row, raw) {
			t.Fatal("token stored in the clear")
		}
	}
	if _, _, err := store.IssueAccess(ctx, 999); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
}

// One live access token per device: issuing a new one replaces the old hash.
func TestOneAccessTokenPerDevice(t *testing.T) {
	store, _, _ := openStore(t)
	device := approvedDevice(t, store)
	first, _, _ := store.IssueAccess(ctx, device.ID)
	second, _, _ := store.IssueAccess(ctx, device.ID)
	got, _ := store.Device(ctx, device.ID)
	firstHash, secondHash := HashToken(first), HashToken(second)
	if bytes.Equal(got.AccessHash, firstHash[:]) || !bytes.Equal(got.AccessHash, secondHash[:]) {
		t.Fatal("old access token still live")
	}
}

func accept(Device) error { return nil }

func TestRefreshRotates(t *testing.T) {
	store, clock, _ := openStore(t)
	device := approvedDevice(t, store)
	token1, _, _ := store.IssueRefresh(ctx, device.ID)
	clock.Advance(time.Hour)
	var verified Device
	tokens, err := store.Refresh(ctx, token1, func(d Device) error { verified = d; return nil })
	if err != nil || verified.ID != device.ID || !bytes.Equal(verified.PublicKey, deviceKey(1)) {
		t.Fatal(err)
	}
	if !strings.HasPrefix(tokens.Access, AccessPrefix) || !strings.HasPrefix(tokens.Refresh, RefreshPrefix) || tokens.Refresh == token1 ||
		!tokens.AccessExpiresAt.Equal(clock.Now().Add(AccessLifetime)) || !tokens.RefreshExpiresAt.Equal(clock.Now().Add(RefreshLifetime)) || tokens.DeviceID != device.ID || tokens.UserID != device.UserID {
		t.Fatalf("%+v", tokens)
	}
	got, _ := store.Device(ctx, device.ID)
	h1, h2, access := HashToken(token1), HashToken(tokens.Refresh), HashToken(tokens.Access)
	if !bytes.Equal(got.PreviousRefreshHash, h1[:]) || !bytes.Equal(got.RefreshHash, h2[:]) || !bytes.Equal(got.AccessHash, access[:]) {
		t.Fatalf("%+v", got)
	}
	again, err := store.Refresh(ctx, tokens.Refresh, accept)
	if err != nil {
		t.Fatal(err)
	}
	got, _ = store.Device(ctx, device.ID)
	h3 := HashToken(again.Refresh)
	if !bytes.Equal(got.PreviousRefreshHash, h2[:]) || !bytes.Equal(got.RefreshHash, h3[:]) {
		t.Fatal("previous hash must track the token just replaced")
	}
}

func reject(Device) error { return ErrUnauthorized }

// Presenting the previous refresh token without a valid device signature
// revokes the device, clears its hashes and writes refresh_reuse; the current
// token is dead afterwards.
func TestRefreshReuseRevokesDevice(t *testing.T) {
	store, _, _ := openStore(t)
	device := approvedDevice(t, store)
	token1, _, _ := store.IssueRefresh(ctx, device.ID)
	tokens, err := store.Refresh(ctx, token1, accept)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Refresh(ctx, token1, reject); !errors.Is(err, ErrRefreshReuse) {
		t.Fatal(err)
	}
	got, _ := store.Device(ctx, device.ID)
	if got.State != DeviceRevoked || got.RefreshHash != nil || got.PreviousRefreshHash != nil || got.AccessHash != nil {
		t.Fatalf("%+v", got)
	}
	entries, _ := store.AuditLog(ctx, 1)
	if len(entries) != 1 || entries[0].Action != "refresh_reuse" || entries[0].Target != DeviceTarget(device.ID) || entries[0].Outcome != "revoked" {
		t.Fatalf("%+v", entries)
	}
	// Both tokens of the revoked lineage are now answered revoked, and the
	// replayed one no longer triggers reuse handling.
	for _, token := range []string{tokens.Refresh, token1} {
		if _, err := store.Refresh(ctx, token, accept); !errors.Is(err, ErrRevoked) {
			t.Fatal(err)
		}
	}
	entries, _ = store.AuditLog(ctx, 10)
	reuses := 0
	for _, e := range entries {
		if e.Action == "refresh_reuse" {
			reuses++
		}
	}
	if reuses != 1 {
		t.Fatalf("%+v", entries)
	}
}

// After an admin revocation the device's current and previous refresh tokens
// are answered revoked; the tombstone never redeems anything, and once the
// device is approved again the old tokens are simply unknown.
func TestRefreshTombstone(t *testing.T) {
	store, _, _ := openStore(t)
	device := approvedDevice(t, store)
	previous, _, _ := store.IssueRefresh(ctx, device.ID)
	tokens, err := store.Refresh(ctx, previous, accept)
	if err != nil {
		t.Fatal(err)
	}
	_ = store.SetDeviceState(ctx, device.ID, DeviceRevoked, AdminActor("oliver"))
	verified := false
	for _, token := range []string{tokens.Refresh, previous} {
		_, err := store.Refresh(ctx, token, func(Device) error { verified = true; return nil })
		if !errors.Is(err, ErrRevoked) {
			t.Fatal(err)
		}
	}
	got, _ := store.Device(ctx, device.ID)
	if verified || got.State != DeviceRevoked || got.RefreshHash != nil || got.PreviousRefreshHash != nil || got.AccessHash != nil {
		t.Fatalf("tombstone must not redeem or change the device: %+v", got)
	}
	_ = store.SetDeviceState(ctx, device.ID, DeviceApproved, AdminActor("oliver"))
	for _, token := range []string{tokens.Refresh, previous} {
		if _, err := store.Refresh(ctx, token, accept); !errors.Is(err, ErrUnauthorized) {
			t.Fatal("after re-approval", err)
		}
	}
}

// not_approved keeps the refresh token valid and unrotated.
func TestRefreshNotApprovedKeepsToken(t *testing.T) {
	store, _, _ := openStore(t)
	user, _, _ := store.EnsureUser(ctx, "google", "sub", "")
	device, _ := store.AddDevice(ctx, user.ID, "Mac", deviceKey(1))
	token, _, _ := store.IssueRefresh(ctx, device.ID)
	before, _ := store.Device(ctx, device.ID)
	if _, err := store.Refresh(ctx, token, accept); !errors.Is(err, ErrNotApproved) {
		t.Fatal(err)
	}
	// Approving only the device is not enough; the user must be approved too.
	_ = store.SetDeviceState(ctx, device.ID, DeviceApproved, AdminActor("oliver"))
	if _, err := store.Refresh(ctx, token, accept); !errors.Is(err, ErrNotApproved) {
		t.Fatal(err)
	}
	after, _ := store.Device(ctx, device.ID)
	if !bytes.Equal(before.RefreshHash, after.RefreshHash) || after.PreviousRefreshHash != nil || after.AccessHash != nil {
		t.Fatal("not_approved rotated the token")
	}
	_ = store.SetUserState(ctx, user.ID, UserApproved, AdminActor("oliver"))
	if _, err := store.Refresh(ctx, token, accept); err != nil {
		t.Fatal("token must still work after approval", err)
	}
}

func TestRefreshRefusals(t *testing.T) {
	store, clock, _ := openStore(t)
	device := approvedDevice(t, store)
	token, _, _ := store.IssueRefresh(ctx, device.ID)
	if _, err := store.Refresh(ctx, "lfr_"+strings.Repeat("A", 43), accept); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("unknown token", err)
	}
	failure := errors.New("bad signature")
	if _, err := store.Refresh(ctx, token, func(Device) error { return failure }); !errors.Is(err, failure) {
		t.Fatal(err)
	}
	if got, _ := store.Device(ctx, device.ID); got.PreviousRefreshHash != nil || got.State != DeviceApproved {
		t.Fatal("a failed signature changed the device")
	}
	_ = store.SetUserState(ctx, device.UserID, UserRevoked, AdminActor("oliver"))
	if _, err := store.Refresh(ctx, token, accept); !errors.Is(err, ErrRevoked) {
		t.Fatal("revoked user", err)
	}
	_ = store.SetUserState(ctx, device.UserID, UserApproved, AdminActor("oliver"))
	clock.Advance(RefreshLifetime)
	if _, err := store.Refresh(ctx, token, accept); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("expired by the server clock", err)
	}
}

// A signed refresh with the previous token is the device retrying after the
// reply to its last refresh was lost: it gets a new pair, the token it never
// received is forgotten, and nothing is revoked or audited.
func TestRefreshSignedReplayAfterALostReplyReissues(t *testing.T) {
	store, _, _ := openStore(t)
	device := approvedDevice(t, store)
	token1, _, _ := store.IssueRefresh(ctx, device.ID)
	lost, err := store.Refresh(ctx, token1, accept)
	if err != nil {
		t.Fatal(err)
	}
	var verified Device
	again, err := store.Refresh(ctx, token1, func(d Device) error { verified = d; return nil })
	if err != nil || verified.ID != device.ID {
		t.Fatal(err)
	}
	if again.Refresh == lost.Refresh || again.Access == lost.Access {
		t.Fatal("expected a new pair")
	}
	got, _ := store.Device(ctx, device.ID)
	h1, h3 := HashToken(token1), HashToken(again.Refresh)
	if got.State != DeviceApproved || !bytes.Equal(got.PreviousRefreshHash, h1[:]) || !bytes.Equal(got.RefreshHash, h3[:]) {
		t.Fatalf("%+v", got)
	}
	// The pair that never arrived is dead.
	if _, err := store.Refresh(ctx, lost.Refresh, accept); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	entries, _ := store.AuditLog(ctx, 10)
	for _, e := range entries {
		if e.Action == "refresh_reuse" || e.Action == "revoke" {
			t.Fatalf("%+v", entries)
		}
	}
	// The new token refreshes normally.
	if _, err := store.Refresh(ctx, again.Refresh, accept); err != nil {
		t.Fatal(err)
	}
}
