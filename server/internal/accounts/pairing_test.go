package accounts

import (
	"bytes"
	"encoding/base64"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

var (
	testServerKey = make([]byte, 32)
	testAdmin     = AdminActor("oliver")
)

func newToken(t *testing.T, store *Store, userID int64) (string, PairingToken) {
	t.Helper()
	value, row, err := store.CreatePairingToken(ctx, testServerKey, "Anna's phone", userID, DefaultPairingLifetime, testAdmin)
	if err != nil {
		t.Fatal(err)
	}
	return value, row
}

func tokenState(t *testing.T, store *Store, id int64) PairingState {
	t.Helper()
	tokens, err := store.PairingTokens(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, token := range tokens {
		if token.ID == id {
			return token.State
		}
	}
	t.Fatalf("token %d is gone", id)
	return ""
}

func approvedUser(t *testing.T, store *Store, subject string) User {
	t.Helper()
	user, _, err := store.EnsureUser(ctx, "apple", subject, "")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetUserState(ctx, user.ID, UserApproved, testAdmin); err != nil {
		t.Fatal(err)
	}
	return user
}

func acceptAny(Device) error { return nil }

func TestPairingTokenFormat(t *testing.T) {
	key := make([]byte, 32)
	key[0] = 0xab
	value, hash, err := NewPairingToken(key)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(value, PairingPrefix) || len(value) != len(PairingPrefix)+86 || hash != HashToken(value) {
		t.Fatal(value)
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(value, PairingPrefix))
	if err != nil || len(raw) != 64 || string(raw[:32]) != string(key) {
		t.Fatal(raw, err)
	}
	other, _, _ := NewPairingToken(key)
	if other == value {
		t.Fatal("tokens must differ")
	}
	if _, _, err := NewPairingToken(key[:31]); !errors.Is(err, ErrInvalidRecord) {
		t.Fatal(err)
	}
}

func TestCreatePairingTokenValidation(t *testing.T) {
	store, _, _ := openStore(t)
	cases := []struct {
		label    string
		lifetime time.Duration
		actor    string
	}{
		{"", time.Hour, testAdmin},
		{strings.Repeat("x", 65), time.Hour, testAdmin},
		{"a\nb", time.Hour, testAdmin},
		{"ok", 2 * time.Hour, testAdmin},
		{"ok", time.Hour, SystemActor},
		{"ok", time.Hour, DeviceActor(1)},
	}
	for _, c := range cases {
		if _, _, err := store.CreatePairingToken(ctx, testServerKey, c.label, 0, c.lifetime, c.actor); !errors.Is(err, ErrInvalidRecord) {
			t.Errorf("%+v: %v", c, err)
		}
	}
	for _, lifetime := range []time.Duration{time.Hour, 24 * time.Hour, 7 * 24 * time.Hour} {
		if _, row, err := store.CreatePairingToken(ctx, testServerKey, "ok", 0, lifetime, testAdmin); err != nil || row.ExpiresAt.Sub(row.CreatedAt) != lifetime {
			t.Errorf("%v: %+v %v", lifetime, row, err)
		}
	}
	if _, _, err := store.CreatePairingToken(ctx, testServerKey, "ok", 99, time.Hour, testAdmin); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	pending, _, _ := store.EnsureUser(ctx, "apple", "pending", "")
	var transition *TransitionError
	if _, _, err := store.CreatePairingToken(ctx, testServerKey, "ok", pending.ID, time.Hour, testAdmin); !errors.As(err, &transition) {
		t.Fatal(err)
	}
}

// The hash is the only stored form, and no value reaches any column.
func TestPairingTokenStoredAsHashOnly(t *testing.T) {
	store, _, _ := openStore(t)
	value, row := newToken(t, store, 0)
	var hash []byte
	if err := store.db.QueryRow(`SELECT hash FROM pairing_tokens WHERE id = ?`, row.ID).Scan(&hash); err != nil {
		t.Fatal(err)
	}
	want := HashToken(value)
	if string(hash) != string(want[:]) {
		t.Fatal("stored form is not HashToken")
	}
	var matches int
	if err := store.db.QueryRow(`SELECT count(*) FROM pairing_tokens WHERE label = ?1 OR created_by = ?1 OR hash = ?1`, value).Scan(&matches); err != nil || matches != 0 {
		t.Fatal(matches, err)
	}
}

func TestPairingTokenCapAndPruning(t *testing.T) {
	store, clock, _ := openStore(t)
	for range MaxLivePairingTokens {
		newToken(t, store, 0)
	}
	if _, _, err := store.CreatePairingToken(ctx, testServerKey, "over", 0, time.Hour, testAdmin); !errors.Is(err, ErrPairingTokenLimit) {
		t.Fatal(err)
	}
	// A revoked or redeemed token doesn't count, and neither does an expired one.
	if err := store.RevokePairingToken(ctx, 1, testAdmin); err != nil {
		t.Fatal(err)
	}
	newToken(t, store, 0)
	clock.Advance(DefaultPairingLifetime + time.Second)
	newToken(t, store, 0)
	if tokens, err := store.PairingTokens(ctx); err != nil || len(tokens) != MaxLivePairingTokens+2 {
		t.Fatal(len(tokens), err)
	}
	// Over 90 days past every change and expiry, the old rows go in one create.
	clock.Advance(pairingRetention + DefaultPairingLifetime + time.Second)
	newToken(t, store, 0)
	if tokens, err := store.PairingTokens(ctx); err != nil || len(tokens) != 1 {
		t.Fatal(len(tokens), err)
	}
}

// Pruning must not free an id: a token user's subject keeps it.
func TestPairingTokenIDsAreNotReused(t *testing.T) {
	store, clock, _ := openStore(t)
	value, row := newToken(t, store, 0)
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), ""); err != nil {
		t.Fatal(err)
	}
	clock.Advance(pairingRetention + time.Hour)
	next, nextRow := newToken(t, store, 0)
	if nextRow.ID == row.ID {
		t.Fatal("id reused")
	}
	if tokens, _ := store.PairingTokens(ctx); len(tokens) != 1 {
		t.Fatal("the old row was not pruned")
	}
	if _, err := store.RedeemPairingToken(ctx, next, "Phone 2", deviceKey(2), ""); err != nil {
		t.Fatal(err)
	}
}

func TestRedeemCreatesApprovedTokenUser(t *testing.T) {
	store, clock, _ := openStore(t)
	value, row := newToken(t, store, 0)
	pairing, err := store.RedeemPairingToken(ctx, value, "Anna's iPhone", deviceKey(1), "")
	if err != nil {
		t.Fatal(err)
	}
	user, err := store.User(ctx, pairing.UserID)
	if err != nil || user.Provider != "token" || user.Subject != TokenTarget(row.ID) || user.Display != row.Label || user.State != UserApproved {
		t.Fatalf("%+v %v", user, err)
	}
	device, err := store.DeviceByKey(ctx, deviceKey(1))
	if err != nil || device.ID != pairing.DeviceID || device.UserID != user.ID || device.State != DeviceApproved || device.Name != "Anna's iPhone" {
		t.Fatalf("%+v %v", device, err)
	}
	if !pairing.RefreshExpiresAt.Equal(time.UnixMilli(clock.Now().Add(RefreshLifetime).UnixMilli())) {
		t.Fatal(pairing.RefreshExpiresAt)
	}
	tokens, err := store.Refresh(ctx, pairing.Refresh, acceptAny)
	if err != nil || tokens.DeviceID != device.ID || tokens.UserID != user.ID {
		t.Fatalf("%+v %v", tokens, err)
	}
	listed, _ := store.PairingTokens(ctx)
	if listed[0].State != PairingRedeemed || listed[0].UserID != user.ID || listed[0].DeviceID != device.ID {
		t.Fatalf("%+v", listed[0])
	}
}

func TestRedeemForExistingUserAddsDevice(t *testing.T) {
	store, _, _ := openStore(t)
	user := approvedUser(t, store, "anna")
	pending, err := store.AddDevice(ctx, user.ID, "Mac", deviceKey(2), "")
	if err != nil {
		t.Fatal(err)
	}
	value, _ := newToken(t, store, user.ID)
	pairing, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), "")
	if err != nil || pairing.UserID != user.ID {
		t.Fatalf("%+v %v", pairing, err)
	}
	// The device the user already has, pending, is approved by a token too.
	value, _ = newToken(t, store, user.ID)
	pairing, err = store.RedeemPairingToken(ctx, value, "ignored", deviceKey(2), "")
	if err != nil || pairing.DeviceID != pending.ID {
		t.Fatalf("%+v %v", pairing, err)
	}
	device, _ := store.Device(ctx, pending.ID)
	if device.State != DeviceApproved || device.Name != "Mac" {
		t.Fatalf("%+v", device)
	}
	if users, _ := store.Users(ctx); len(users) != 1 {
		t.Fatalf("%+v", users)
	}
}

func TestRedeemConcurrentlyOnlyOneWins(t *testing.T) {
	store, _, _ := openStore(t)
	value, _ := newToken(t, store, 0)
	var wg sync.WaitGroup
	results := make([]error, 8)
	for i := range results {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, results[i] = store.RedeemPairingToken(ctx, value, "Phone", deviceKey(byte(i+1)), "")
		}()
	}
	wg.Wait()
	won := 0
	for _, err := range results {
		switch {
		case err == nil:
			won++
		case !errors.Is(err, ErrPairingTokenInvalid):
			t.Fatal(err)
		}
	}
	devices, _ := store.Devices(ctx, 0)
	users, _ := store.Users(ctx)
	if won != 1 || len(devices) != 1 || len(users) != 1 {
		t.Fatal(won, devices, users)
	}
}

func TestRedeemSameKeyRetryGetsNewLineage(t *testing.T) {
	store, clock, _ := openStore(t)
	value, _ := newToken(t, store, 0)
	first, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), "")
	if err != nil {
		t.Fatal(err)
	}
	retry, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), "")
	if err != nil || retry.DeviceID != first.DeviceID || retry.UserID != first.UserID || retry.Refresh == first.Refresh {
		t.Fatalf("%+v %v", retry, err)
	}
	// The lost reply's refresh token is gone; the retry's works.
	if _, err := store.Refresh(ctx, first.Refresh, acceptAny); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if _, err := store.Refresh(ctx, retry.Refresh, acceptAny); err != nil {
		t.Fatal(err)
	}
	if devices, _ := store.Devices(ctx, 0); len(devices) != 1 {
		t.Fatal(devices)
	}
	// Not after expiry.
	clock.Advance(DefaultPairingLifetime)
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), ""); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}
}

func TestRedeemOtherKeyRefused(t *testing.T) {
	store, _, _ := openStore(t)
	value, _ := newToken(t, store, 0)
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RedeemPairingToken(ctx, value, "Thief", deviceKey(2), ""); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}
	if _, err := store.DeviceByKey(ctx, deviceKey(2)); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
}

func TestRedeemInvalidTokens(t *testing.T) {
	store, clock, _ := openStore(t)
	if _, err := store.RedeemPairingToken(ctx, "lfp_unknown", "Phone", deviceKey(1), ""); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}
	revoked, row := newToken(t, store, 0)
	if err := store.RevokePairingToken(ctx, row.ID, testAdmin); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RedeemPairingToken(ctx, revoked, "Phone", deviceKey(1), ""); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}
	expired, row := newToken(t, store, 0)
	clock.Advance(DefaultPairingLifetime)
	if tokenState(t, store, row.ID) != PairingExpired {
		t.Fatal("expiry is derived in listings")
	}
	if _, err := store.RedeemPairingToken(ctx, expired, "Phone", deviceKey(1), ""); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}
	if devices, _ := store.Devices(ctx, 0); len(devices) != 0 {
		t.Fatal(devices)
	}
	if _, err := store.RedeemPairingToken(ctx, expired, "", deviceKey(1), ""); !errors.Is(err, ErrInvalidRecord) {
		t.Fatal(err)
	}
	if _, err := store.RedeemPairingToken(ctx, expired, "Phone", deviceKey(1)[:64], ""); !errors.Is(err, ErrInvalidRecord) {
		t.Fatal(err)
	}
}

// Each refusal keeps the token spendable, by a key that isn't refused.
func TestRedeemRefusalsLeaveTokenUnspent(t *testing.T) {
	store, _, _ := openStore(t)
	owner := approvedUser(t, store, "owner")
	if _, err := store.AddDevice(ctx, owner.ID, "Mac", deviceKey(1), ""); err != nil {
		t.Fatal(err)
	}
	gone, err := store.AddDevice(ctx, owner.ID, "Old", deviceKey(2), "")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetDeviceState(ctx, gone.ID, DeviceRevoked, testAdmin); err != nil {
		t.Fatal(err)
	}

	value, row := newToken(t, store, 0)
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), ""); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(2), ""); !errors.Is(err, ErrRevoked) {
		t.Fatal(err)
	}
	if tokenState(t, store, row.ID) != PairingLive {
		t.Fatal("token spent")
	}
	if users, _ := store.Users(ctx); len(users) != 1 {
		t.Fatalf("a refused new-user token created a user: %+v", users)
	}

	other := approvedUser(t, store, "other")
	value, row = newToken(t, store, other.ID)
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), ""); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if err := store.SetUserState(ctx, other.ID, UserRevoked, testAdmin); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(3), ""); !errors.Is(err, ErrRevoked) {
		t.Fatal(err)
	}
	if _, err := store.DeviceByKey(ctx, deviceKey(3)); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	if tokenState(t, store, row.ID) != PairingLive {
		t.Fatal("token spent")
	}
	// The user approved again, the same token works.
	if err := store.SetUserState(ctx, other.ID, UserApproved, testAdmin); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(3), ""); err != nil {
		t.Fatal(err)
	}
}

// A retry never revives what an administrator has revoked.
func TestRedeemRetryAfterRevocation(t *testing.T) {
	store, _, _ := openStore(t)
	value, _ := newToken(t, store, 0)
	pairing, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), "")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetDeviceState(ctx, pairing.DeviceID, DeviceRevoked, testAdmin); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), ""); !errors.Is(err, ErrRevoked) {
		t.Fatal(err)
	}
	if err := store.SetDeviceState(ctx, pairing.DeviceID, DeviceApproved, testAdmin); err != nil {
		t.Fatal(err)
	}
	if err := store.SetUserState(ctx, pairing.UserID, UserRevoked, testAdmin); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), ""); !errors.Is(err, ErrRevoked) {
		t.Fatal(err)
	}
}

// A failure late in the transaction leaves no user, device or refresh token.
func TestRedeemIsAtomic(t *testing.T) {
	store, _, _ := openStore(t)
	value, row := newToken(t, store, 0)
	if _, err := store.db.Exec(`CREATE TRIGGER fail_refresh BEFORE UPDATE OF refresh_hash ON devices BEGIN SELECT RAISE(ABORT, 'injected'); END`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), ""); err == nil {
		t.Fatal("the injected failure must surface")
	}
	users, _ := store.Users(ctx)
	devices, _ := store.Devices(ctx, 0)
	if len(users) != 0 || len(devices) != 0 || tokenState(t, store, row.ID) != PairingLive {
		t.Fatal(users, devices)
	}
	if _, err := store.db.Exec(`DROP TRIGGER fail_refresh`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), ""); err != nil {
		t.Fatal(err)
	}
}

func TestRevokePairingToken(t *testing.T) {
	store, _, _ := openStore(t)
	if err := store.RevokePairingToken(ctx, 1, testAdmin); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	_, row := newToken(t, store, 0)
	if err := store.RevokePairingToken(ctx, row.ID, testAdmin); err != nil {
		t.Fatal(err)
	}
	var transition *TransitionError
	if err := store.RevokePairingToken(ctx, row.ID, testAdmin); !errors.As(err, &transition) {
		t.Fatal(err)
	}
	value, row := newToken(t, store, 0)
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), ""); err != nil {
		t.Fatal(err)
	}
	if err := store.RevokePairingToken(ctx, row.ID, testAdmin); !errors.As(err, &transition) {
		t.Fatal(err)
	}
}

func TestPairingAudit(t *testing.T) {
	store, _, _ := openStore(t)
	value, row := newToken(t, store, 0)
	target := TokenTarget(row.ID)
	pairing, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(1), "")
	if err != nil {
		t.Fatal(err)
	}
	store.RedeemPairingToken(ctx, value, "Thief", deviceKey(2), "")
	store.RedeemPairingToken(ctx, "lfp_unknown", "Phone", deviceKey(3), "")
	_, revoked := newToken(t, store, 0)
	if err := store.RevokePairingToken(ctx, revoked.ID, testAdmin); err != nil {
		t.Fatal(err)
	}
	want := []AuditEntry{
		{Actor: testAdmin, Action: "token_create", Target: target, Outcome: "ok"},
		{Actor: DeviceActor(pairing.DeviceID), Action: "pair", Target: target, Outcome: "ok"},
		{Actor: SystemActor, Action: "pair", Target: target, Outcome: "pairing_token_invalid"},
		{Actor: testAdmin, Action: "token_create", Target: TokenTarget(revoked.ID), Outcome: "ok"},
		{Actor: testAdmin, Action: "token_revoke", Target: TokenTarget(revoked.ID), Outcome: "ok"},
	}
	entries, err := store.AuditLog(ctx, 10)
	if err != nil || len(entries) != len(want) {
		t.Fatalf("%+v %v", entries, err)
	}
	for i, w := range want {
		got := entries[len(entries)-1-i]
		if got.Actor != w.Actor || got.Action != w.Action || got.Target != w.Target || got.Outcome != w.Outcome {
			t.Errorf("row %d: %+v, want %+v", i, got, w)
		}
	}
}

// A redemption stores its kind on a new device and fills an unknown kind on the
// key's existing device, or on a retry by the same key; a stored kind stays.
func TestRedeemDeviceKind(t *testing.T) {
	store, _, _ := openStore(t)
	value, _ := newToken(t, store, 0)
	pairing, err := store.RedeemPairingToken(ctx, value, "Anna's iPhone", deviceKey(1), KindIPhone)
	if err != nil {
		t.Fatal(err)
	}
	if d, _ := store.Device(ctx, pairing.DeviceID); d.Kind != KindIPhone {
		t.Fatal(d.Kind)
	}
	// The retry may not change it.
	if _, err := store.RedeemPairingToken(ctx, value, "Anna's iPhone", deviceKey(1), KindMac); err != nil {
		t.Fatal(err)
	}
	if d, _ := store.Device(ctx, pairing.DeviceID); d.Kind != KindIPhone {
		t.Fatal("a stored kind changed", d.Kind)
	}

	user := approvedUser(t, store, "oliver")
	pending, _ := store.AddDevice(ctx, user.ID, "Mac", deviceKey(2), KindUnknown)
	value, _ = newToken(t, store, user.ID)
	if _, err := store.RedeemPairingToken(ctx, value, "Mac", deviceKey(2), KindMac); err != nil {
		t.Fatal(err)
	}
	if d, _ := store.Device(ctx, pending.ID); d.Kind != KindMac || d.State != DeviceApproved {
		t.Fatalf("%+v", d)
	}

	// No kind stores NULL; an unknown kind is refused before the token is touched.
	value, row := newToken(t, store, 0)
	if _, err := store.RedeemPairingToken(ctx, value, "Phone", deviceKey(3), DeviceKind("linux")); !errors.Is(err, ErrInvalidRecord) {
		t.Fatal(err)
	}
	pairing, err = store.RedeemPairingToken(ctx, value, "Phone", deviceKey(3), KindUnknown)
	if err != nil || pairing.TokenID != row.ID {
		t.Fatal(pairing, err)
	}
	if d, _ := store.Device(ctx, pairing.DeviceID); d.Kind != KindUnknown {
		t.Fatal(d.Kind)
	}
}

// Redeeming an invite adds a pending device to the inviting device's user, moves
// the invite to awaiting_confirm with the binding and a deadline 10 minutes
// after redemption, and returns the inviting device's key. It is single use.
func TestRedeemInvite(t *testing.T) {
	store, clock, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	value, row := invite(t, store, mac.ID)
	clock.Advance(3 * time.Minute)
	pairing := redeemInvite(t, store, value, 2)
	if pairing.State != DevicePending || pairing.UserID != mac.UserID || !bytes.Equal(pairing.InviterKey, deviceKey(1)) ||
		!pairing.ConfirmBy.Equal(clock.Now().Add(InviteConfirmWindow)) || !strings.HasPrefix(pairing.Refresh, RefreshPrefix) {
		t.Fatalf("%+v", pairing)
	}
	device, err := store.Device(ctx, pairing.DeviceID)
	if err != nil || device.State != DevicePending || device.UserID != mac.UserID || device.Kind != KindIPhone {
		t.Fatalf("%+v %v", device, err)
	}
	var binding []byte
	if err := store.db.QueryRow(`SELECT pair_binding FROM pairing_tokens WHERE id = ?`, row.ID).Scan(&binding); err != nil || !bytes.Equal(binding, testBinding) {
		t.Fatal(err)
	}
	if tokenState(t, store, row.ID) != PairingAwaitingConfirm {
		t.Fatal("not awaiting confirmation")
	}
	// Single use, even for the same key (the reply can't be replayed into a
	// second pending lineage).
	for _, key := range []byte{2, 3} {
		if _, err := store.Redeem(ctx, value, "iPhone", deviceKey(key), "", testBinding); !errors.Is(err, ErrPairingTokenInvalid) {
			t.Fatal(key, err)
		}
	}
	// Without a binding (the admin path) an invite is not accepted.
	other, _ := invite(t, store, mac.ID)
	if _, err := store.RedeemPairingToken(ctx, other, "iPhone", deviceKey(4), ""); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}
	if _, err := store.Redeem(ctx, other, "iPhone", deviceKey(4), "", []byte{1}); !errors.Is(err, ErrInvalidRecord) {
		t.Fatal(err)
	}
}

// Refusals leave the invite unspent: a key on another user is unauthorized, a
// key already on the same user and a revoked inviter are pairing_token_invalid,
// and an expired invite is pairing_token_invalid.
func TestRedeemInviteRefusals(t *testing.T) {
	store, clock, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	stranger := inviter(t, store, "stranger", 2)
	sibling, err := store.AddDevice(ctx, mac.UserID, "Sibling", deviceKey(3), "")
	if err != nil {
		t.Fatal(err)
	}
	value, row := invite(t, store, mac.ID)
	if _, err := store.Redeem(ctx, value, "iPhone", deviceKey(2), "", testBinding); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if _, err := store.Redeem(ctx, value, "iPhone", deviceKey(3), "", testBinding); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}
	if tokenState(t, store, row.ID) != PairingLive {
		t.Fatal("refusal spent the invite")
	}
	if d, _ := store.Device(ctx, stranger.ID); d.UserID == mac.UserID {
		t.Fatal("moved between users")
	}
	if d, _ := store.Device(ctx, sibling.ID); d.State != DevicePending {
		t.Fatal("sibling changed")
	}
	redeemInvite(t, store, value, 4)

	// Expired before redemption.
	value, _ = invite(t, store, mac.ID)
	clock.Advance(InviteLifetime)
	if _, err := store.Redeem(ctx, value, "iPhone", deviceKey(5), "", testBinding); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}

	// The inviter revoked behind the cascade's back (a direct write) is still
	// refused at redemption.
	value, row = invite(t, store, mac.ID)
	if _, err := store.db.Exec(`UPDATE devices SET state = 'revoked' WHERE id = ?`, mac.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Redeem(ctx, value, "iPhone", deviceKey(6), "", testBinding); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}
	if tokenState(t, store, row.ID) != PairingLive {
		t.Fatal("refusal spent the invite")
	}
	if _, err := store.DeviceByKey(ctx, deviceKey(6)); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
}
