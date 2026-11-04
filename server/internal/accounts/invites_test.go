package accounts

import (
	"bytes"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"
)

var testBinding = bytes.Repeat([]byte{0x5a}, 32)

// inviter returns an approved device on an approved user.
func inviter(t *testing.T, store *Store, subject string, key byte) Device {
	t.Helper()
	user := approvedUser(t, store, subject)
	device, err := store.AddDevice(ctx, user.ID, "Mac", deviceKey(key), KindMac)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetDeviceState(ctx, device.ID, DeviceApproved, testAdmin); err != nil {
		t.Fatal(err)
	}
	device.State = DeviceApproved
	return device
}

func invite(t *testing.T, store *Store, deviceID int64) (string, PairingToken) {
	t.Helper()
	value, row, err := store.CreateInvite(ctx, testServerKey, deviceID)
	if err != nil {
		t.Fatal(err)
	}
	return value, row
}

func redeemInvite(t *testing.T, store *Store, value string, key byte) Pairing {
	t.Helper()
	pairing, err := store.Redeem(ctx, value, "iPhone", deviceKey(key), KindIPhone, testBinding)
	if err != nil {
		t.Fatal(err)
	}
	return pairing
}

func acceptSignature(callerKey, newKey, binding []byte) bool { return true }

func auditLines(t *testing.T, store *Store) []string {
	t.Helper()
	entries, err := store.AuditLog(ctx, 200)
	if err != nil {
		t.Fatal(err)
	}
	var lines []string
	for _, e := range entries {
		lines = append(lines, e.Action+" "+e.Actor+" "+e.Target+" "+e.Outcome)
	}
	return lines
}

// An invite targets the device's own user, lives 10 minutes, is a token in the
// pairing format stored only as its hash, and is audited without its value.
func TestCreateInvite(t *testing.T) {
	store, _, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	value, row := invite(t, store, mac.ID)
	if !strings.HasPrefix(value, PairingPrefix) || row.UserID != mac.UserID || row.ExpiresAt.Sub(row.CreatedAt) != InviteLifetime ||
		row.CreatedBy != DeviceActor(mac.ID) || row.State != PairingLive {
		t.Fatalf("%+v", row)
	}
	var purpose string
	var inviterID int64
	if err := store.db.QueryRow(`SELECT purpose, inviter_device_id FROM pairing_tokens WHERE id = ?`, row.ID).Scan(&purpose, &inviterID); err != nil ||
		purpose != "invite" || inviterID != mac.ID {
		t.Fatal(purpose, inviterID, err)
	}
	var matches int
	if err := store.db.QueryRow(`SELECT count(*) FROM pairing_tokens WHERE label = ?1 OR created_by = ?1 OR hash = ?1`, value).Scan(&matches); err != nil || matches != 0 {
		t.Fatal("token value stored", err)
	}
	if got := auditLines(t, store); got[0] != "invite_create "+DeviceActor(mac.ID)+" "+TokenTarget(row.ID)+" ok" {
		t.Fatal(got)
	}
}

// Only an approved device of an approved user may invite.
func TestCreateInviteNeedsApproval(t *testing.T) {
	store, _, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	pending, err := store.AddDevice(ctx, mac.UserID, "Pending", deviceKey(2), "")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.CreateInvite(ctx, testServerKey, pending.ID); !errors.Is(err, ErrNotApproved) {
		t.Fatal(err)
	}
	if _, _, err := store.CreateInvite(ctx, testServerKey, 999); !errors.Is(err, ErrNotApproved) {
		t.Fatal(err)
	}
	if err := store.SetUserState(ctx, mac.UserID, UserRevoked, testAdmin); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.CreateInvite(ctx, testServerKey, mac.ID); !errors.Is(err, ErrNotApproved) {
		t.Fatal(err)
	}
	if _, _, err := store.CreateInvite(ctx, []byte{1}, mac.ID); !errors.Is(err, ErrInvalidRecord) {
		t.Fatal(err)
	}
}

// A newer invite from the same device revokes its earlier live one.
func TestCreateInviteReplacesOlder(t *testing.T) {
	store, _, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	old, first := invite(t, store, mac.ID)
	_, second := invite(t, store, mac.ID)
	if tokenState(t, store, first.ID) != PairingRevoked || tokenState(t, store, second.ID) != PairingLive {
		t.Fatal("older invite still live")
	}
	if _, err := store.Redeem(ctx, old, "iPhone", deviceKey(9), "", testBinding); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}
}

// At most 3 open invites per user: a device's own replacement doesn't count,
// redeemed-but-unconfirmed ones do, and expired live ones don't.
func TestInviteLimitPerUser(t *testing.T) {
	store, clock, _ := openStore(t)
	a := inviter(t, store, "owner", 1)
	var devices []Device
	for i := byte(2); i <= 5; i++ {
		d, err := store.AddDevice(ctx, a.UserID, "Device", deviceKey(i), "")
		if err != nil {
			t.Fatal(err)
		}
		if err := store.SetDeviceState(ctx, d.ID, DeviceApproved, testAdmin); err != nil {
			t.Fatal(err)
		}
		devices = append(devices, d)
	}
	for _, d := range devices[:3] {
		invite(t, store, d.ID)
	}
	if _, _, err := store.CreateInvite(ctx, testServerKey, devices[3].ID); !errors.Is(err, ErrInviteLimit) {
		t.Fatal(err)
	}
	// Replacing one's own invite stays at 3.
	invite(t, store, devices[0].ID)
	// Another user is not affected.
	b := inviter(t, store, "other", 20)
	invite(t, store, b.ID)
	// Live invites past their 10 minutes stop counting.
	clock.Advance(InviteLifetime)
	value, _ := invite(t, store, devices[3].ID)
	// A redeemed invite awaiting confirmation still counts.
	redeemInvite(t, store, value, 30)
	invite(t, store, devices[0].ID)
	invite(t, store, devices[1].ID)
	if _, _, err := store.CreateInvite(ctx, testServerKey, devices[2].ID); !errors.Is(err, ErrInviteLimit) {
		t.Fatal(err)
	}
}

// At most 10 invites created by one device in any hour, counted from rows.
func TestInviteLimitPerDevice(t *testing.T) {
	store, clock, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	for range MaxInvitesPerDeviceHour {
		invite(t, store, mac.ID)
		clock.Advance(time.Minute)
	}
	if _, _, err := store.CreateInvite(ctx, testServerKey, mac.ID); !errors.Is(err, ErrInviteLimit) {
		t.Fatal(err)
	}
	clock.Advance(50*time.Minute + time.Millisecond) // the first one leaves the hour
	invite(t, store, mac.ID)
}

// The server-wide live token cap counts invites, and invites count toward it.
func TestInviteLiveTokenCap(t *testing.T) {
	store, _, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	for range MaxLivePairingTokens {
		newToken(t, store, 0)
	}
	if _, _, err := store.CreateInvite(ctx, testServerKey, mac.ID); !errors.Is(err, ErrInviteLimit) {
		t.Fatal(err)
	}
	if err := store.RevokePairingToken(ctx, 1, testAdmin); err != nil {
		t.Fatal(err)
	}
	invite(t, store, mac.ID)
	if _, _, err := store.CreatePairingToken(ctx, testServerKey, "x", 0, time.Hour, testAdmin); !errors.Is(err, ErrPairingTokenLimit) {
		t.Fatal(err)
	}
}

// Confirming approves the pending device on the inviter's user and spends the
// invite; the signature check gets the inviter's stored key, the new key and
// the pair binding.
func TestConfirmInvite(t *testing.T) {
	store, _, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	value, row := invite(t, store, mac.ID)
	pairing := redeemInvite(t, store, value, 2)
	var got [][]byte
	verify := func(callerKey, newKey, binding []byte) bool {
		got = [][]byte{callerKey, newKey, binding}
		return true
	}
	state, err := store.ConfirmInvite(ctx, mac.ID, row.ID, true, verify)
	if err != nil || state != DeviceApproved {
		t.Fatal(state, err)
	}
	if !bytes.Equal(got[0], deviceKey(1)) || !bytes.Equal(got[1], deviceKey(2)) || !bytes.Equal(got[2], testBinding) {
		t.Fatal("verify got the wrong parts")
	}
	device, err := store.Device(ctx, pairing.DeviceID)
	if err != nil || device.State != DeviceApproved || device.UserID != mac.UserID || device.Kind != KindIPhone {
		t.Fatalf("%+v %v", device, err)
	}
	if tokenState(t, store, row.ID) != PairingRedeemed {
		t.Fatal("invite not redeemed")
	}
	if !slices.Contains(auditLines(t, store), "invite_confirm "+DeviceActor(mac.ID)+" "+TokenTarget(row.ID)+" ok") {
		t.Fatal(auditLines(t, store))
	}
	// The device now refreshes into sessions.
	if _, err := store.Refresh(ctx, pairing.Refresh, acceptAny); err != nil {
		t.Fatal(err)
	}
	// Spent: a second confirmation is refused.
	if _, err := store.ConfirmInvite(ctx, mac.ID, row.ID, true, acceptSignature); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}
}

// SC-007: without a confirmation by the inviting device, an invite never yields
// an approved device: a pending device refreshes into nothing, a bad signature
// or another device (even of the same user) can't confirm, and declining or the
// deadline removes it.
func TestUnconfirmedInviteNeverApproves(t *testing.T) {
	store, clock, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	sibling, err := store.AddDevice(ctx, mac.UserID, "Other Mac", deviceKey(3), "")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetDeviceState(ctx, sibling.ID, DeviceApproved, testAdmin); err != nil {
		t.Fatal(err)
	}
	stranger := inviter(t, store, "stranger", 4)
	value, row := invite(t, store, mac.ID)
	pairing := redeemInvite(t, store, value, 2)
	if pairing.State != DevicePending || !bytes.Equal(pairing.InviterKey, deviceKey(1)) {
		t.Fatalf("%+v", pairing)
	}
	if _, err := store.Refresh(ctx, pairing.Refresh, acceptAny); !errors.Is(err, ErrNotApproved) {
		t.Fatal(err)
	}
	reject := func(callerKey, newKey, binding []byte) bool { return false }
	if _, err := store.ConfirmInvite(ctx, mac.ID, row.ID, true, reject); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	for _, caller := range []int64{sibling.ID, stranger.ID, pairing.DeviceID} {
		if _, err := store.ConfirmInvite(ctx, caller, row.ID, true, acceptSignature); !errors.Is(err, ErrUnauthorized) {
			t.Fatal(caller, err)
		}
	}
	if _, err := store.ConfirmInvite(ctx, mac.ID, row.ID+100, true, acceptSignature); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if device, _ := store.Device(ctx, pairing.DeviceID); device.State != DevicePending {
		t.Fatal("approved without confirmation")
	}
	// The deadline passes: swept to declined, the device deleted.
	clock.Advance(InviteConfirmWindow)
	if _, err := store.ConfirmInvite(ctx, mac.ID, row.ID, true, acceptSignature); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}
	if _, err := store.Device(ctx, pairing.DeviceID); !errors.Is(err, ErrNotFound) {
		t.Fatal("pending device kept past the deadline", err)
	}
	if tokenState(t, store, row.ID) != PairingDeclined {
		t.Fatal("not declined")
	}
	if !slices.Contains(auditLines(t, store), "invite_expire system "+TokenTarget(row.ID)+" ok") {
		t.Fatal(auditLines(t, store))
	}
	// The same key retrying the declined invite is refused.
	if _, err := store.Redeem(ctx, value, "iPhone", deviceKey(2), "", testBinding); !errors.Is(err, ErrPairingTokenInvalid) {
		t.Fatal(err)
	}
}

func TestDeclineInvite(t *testing.T) {
	store, _, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	value, row := invite(t, store, mac.ID)
	pairing := redeemInvite(t, store, value, 2)
	state, err := store.ConfirmInvite(ctx, mac.ID, row.ID, false, acceptSignature)
	if err != nil || state != DeviceRevoked {
		t.Fatal(state, err)
	}
	if _, err := store.Device(ctx, pairing.DeviceID); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	if tokenState(t, store, row.ID) != PairingDeclined {
		t.Fatal("not declined")
	}
	if !slices.Contains(auditLines(t, store), "invite_decline "+DeviceActor(mac.ID)+" "+TokenTarget(row.ID)+" ok") {
		t.Fatal(auditLines(t, store))
	}
	// The key is free again for a fresh invite.
	value, _ = invite(t, store, mac.ID)
	redeemInvite(t, store, value, 2)
}

// ExpireInvites sweeps only invites past their deadline.
func TestExpireInvites(t *testing.T) {
	store, clock, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	value, first := invite(t, store, mac.ID)
	early := redeemInvite(t, store, value, 2)
	clock.Advance(5 * time.Minute)
	other := inviter(t, store, "other", 5)
	value, second := invite(t, store, other.ID)
	late := redeemInvite(t, store, value, 3)
	clock.Advance(5 * time.Minute)
	if err := store.ExpireInvites(ctx); err != nil {
		t.Fatal(err)
	}
	if tokenState(t, store, first.ID) != PairingDeclined || tokenState(t, store, second.ID) != PairingAwaitingConfirm {
		t.Fatal("sweep wrong")
	}
	if _, err := store.Device(ctx, early.DeviceID); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	if _, err := store.Device(ctx, late.DeviceID); err != nil {
		t.Fatal(err)
	}
}

// Revoking the inviting device, or its user, revokes its live invites and
// deletes the pending devices waiting on its invites, in the same transaction.
func TestRevokeCascade(t *testing.T) {
	for _, revokeUser := range []bool{false, true} {
		store, _, _ := openStore(t)
		mac := inviter(t, store, "owner", 1)
		phone, err := store.AddDevice(ctx, mac.UserID, "Phone", deviceKey(2), "")
		if err != nil {
			t.Fatal(err)
		}
		if err := store.SetDeviceState(ctx, phone.ID, DeviceApproved, testAdmin); err != nil {
			t.Fatal(err)
		}
		value, redeemed := invite(t, store, mac.ID)
		pending := redeemInvite(t, store, value, 3)
		live, liveRow := invite(t, store, mac.ID)
		_, phoneRow := invite(t, store, phone.ID)
		if revokeUser {
			err = store.SetUserState(ctx, mac.UserID, UserRevoked, testAdmin)
		} else {
			err = store.SetDeviceState(ctx, mac.ID, DeviceRevoked, testAdmin)
		}
		if err != nil {
			t.Fatal(err)
		}
		if tokenState(t, store, liveRow.ID) != PairingRevoked || tokenState(t, store, redeemed.ID) != PairingDeclined {
			t.Fatal(revokeUser, "invites survived")
		}
		if _, err := store.Device(ctx, pending.DeviceID); !errors.Is(err, ErrNotFound) {
			t.Fatal(revokeUser, err)
		}
		if _, err := store.Redeem(ctx, live, "iPhone", deviceKey(4), "", testBinding); !errors.Is(err, ErrPairingTokenInvalid) {
			t.Fatal(err)
		}
		// Another device's invites survive a device revocation, not a user's.
		want := PairingLive
		if revokeUser {
			want = PairingRevoked
		}
		if tokenState(t, store, phoneRow.ID) != want {
			t.Fatal(revokeUser, tokenState(t, store, phoneRow.ID))
		}
	}
}

// Revoking a pending invited device deletes it and declines its invite;
// approving one with flowd admin confirms its invite.
func TestAdminActsOnInvitedDevice(t *testing.T) {
	store, _, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	value, first := invite(t, store, mac.ID)
	pending := redeemInvite(t, store, value, 2)
	if err := store.SetDeviceState(ctx, pending.DeviceID, DeviceRevoked, testAdmin); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Device(ctx, pending.DeviceID); !errors.Is(err, ErrNotFound) || tokenState(t, store, first.ID) != PairingDeclined {
		t.Fatal(err)
	}
	value, second := invite(t, store, mac.ID)
	pending = redeemInvite(t, store, value, 3)
	if err := store.SetDeviceState(ctx, pending.DeviceID, DeviceApproved, testAdmin); err != nil {
		t.Fatal(err)
	}
	if tokenState(t, store, second.ID) != PairingRedeemed {
		t.Fatal("admin approval did not confirm the invite")
	}
	// Revoking the inviter later leaves the confirmed device alone.
	if err := store.SetDeviceState(ctx, mac.ID, DeviceRevoked, testAdmin); err != nil {
		t.Fatal(err)
	}
	if device, err := store.Device(ctx, pending.DeviceID); err != nil || device.State != DeviceApproved {
		t.Fatalf("%+v %v", device, err)
	}
}

// "Your devices" lists the caller's own user only, leaves out revoked devices,
// and shows invite details only to the device that created the invite.
func TestAccountDevices(t *testing.T) {
	store, _, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	sibling, err := store.AddDevice(ctx, mac.UserID, "Sibling", deviceKey(2), "")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetDeviceState(ctx, sibling.ID, DeviceApproved, testAdmin); err != nil {
		t.Fatal(err)
	}
	gone, err := store.AddDevice(ctx, mac.UserID, "Gone", deviceKey(3), "")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetDeviceState(ctx, gone.ID, DeviceRevoked, testAdmin); err != nil {
		t.Fatal(err)
	}
	inviter(t, store, "stranger", 4)
	value, row := invite(t, store, mac.ID)
	pending := redeemInvite(t, store, value, 5)

	list, err := store.AccountDevices(ctx, mac.ID)
	if err != nil || len(list) != 3 || list[0].ID != mac.ID || list[1].ID != sibling.ID || list[2].ID != pending.DeviceID {
		t.Fatalf("%+v %v", list, err)
	}
	inv := list[2].Invite
	if inv == nil || inv.InviteID != row.ID || !bytes.Equal(inv.DeviceKey, deviceKey(5)) || !bytes.Equal(inv.PairBinding, testBinding) ||
		!inv.ConfirmBy.Equal(pending.ConfirmBy) || list[0].Invite != nil {
		t.Fatalf("%+v", inv)
	}
	list, err = store.AccountDevices(ctx, sibling.ID)
	if err != nil || len(list) != 3 || list[2].Invite != nil {
		t.Fatalf("a device that didn't invite sees the invite: %+v %v", list, err)
	}
}

// A device revokes any device of its own user, itself included; another
// user's device or an unknown one is unauthorized with a cross_user_attempt row.
func TestRevokeAccountDevice(t *testing.T) {
	store, _, _ := openStore(t)
	mac := inviter(t, store, "owner", 1)
	phone, err := store.AddDevice(ctx, mac.UserID, "Phone", deviceKey(2), "")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetDeviceState(ctx, phone.ID, DeviceApproved, testAdmin); err != nil {
		t.Fatal(err)
	}
	stranger := inviter(t, store, "stranger", 3)
	for _, target := range []int64{stranger.ID, 999} {
		if err := store.RevokeAccountDevice(ctx, mac.ID, target); !errors.Is(err, ErrUnauthorized) {
			t.Fatal(err)
		}
		if got := auditLines(t, store)[0]; got != "cross_user_attempt "+DeviceActor(mac.ID)+" "+UserTarget(mac.UserID)+" unauthorized" {
			t.Fatal(got)
		}
	}
	if device, _ := store.Device(ctx, stranger.ID); device.State != DeviceApproved {
		t.Fatal("another user's device revoked")
	}
	if err := store.RevokeAccountDevice(ctx, mac.ID, phone.ID); err != nil {
		t.Fatal(err)
	}
	if got := auditLines(t, store)[0]; got != "revoke "+DeviceActor(mac.ID)+" "+DeviceTarget(phone.ID)+" ok" {
		t.Fatal(got)
	}
	if err := store.RevokeAccountDevice(ctx, mac.ID, phone.ID); err != nil {
		t.Fatal("revoking twice", err)
	}
	// A revoked device can't revoke.
	if err := store.RevokeAccountDevice(ctx, phone.ID, mac.ID); !errors.Is(err, ErrNotApproved) {
		t.Fatal(err)
	}
	// Revoking a pending invited device declines its invite.
	value, row := invite(t, store, mac.ID)
	pending := redeemInvite(t, store, value, 4)
	if err := store.RevokeAccountDevice(ctx, mac.ID, pending.DeviceID); err != nil {
		t.Fatal(err)
	}
	if tokenState(t, store, row.ID) != PairingDeclined {
		t.Fatal("invite not declined")
	}
	// "This wasn't me": the caller revokes itself.
	if err := store.RevokeAccountDevice(ctx, mac.ID, mac.ID); err != nil {
		t.Fatal(err)
	}
	if device, _ := store.Device(ctx, mac.ID); device.State != DeviceRevoked {
		t.Fatal("self-revoke")
	}
	if list, err := store.AccountDevices(ctx, mac.ID); err != nil || len(list) != 0 {
		t.Fatalf("%+v %v", list, err)
	}
}
