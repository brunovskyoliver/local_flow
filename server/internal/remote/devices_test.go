package remote

import (
	"bytes"
	"context"
	"log"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"localflow/server/internal/accounts"
)

// The code and the confirm signature input match the shared vectors.
func TestDeviceCodeVectors(t *testing.T) {
	var file struct {
		Label   string `json:"label"`
		Vectors []struct {
			InviterKey  string `json:"inviter_key"`
			NewKey      string `json:"new_key"`
			PairBinding string `json:"pair_binding"`
			Code        string `json:"code"`
		} `json:"vectors"`
		Confirm struct {
			Label          string `json:"label"`
			SessionBinding string `json:"session_binding"`
			InviteID       int64  `json:"invite_id"`
			NewKey         string `json:"new_key"`
			PairBinding    string `json:"pair_binding"`
			SignatureInput string `json:"signature_input"`
		} `json:"confirm"`
	}
	readFixture(t, "fixtures/remote/device-code.json", &file)
	if file.Label != DeviceCodeLabel || file.Confirm.Label != DeviceConfirmLabel || len(file.Vectors) < 8 {
		t.Fatalf("%s %s %d", file.Label, file.Confirm.Label, len(file.Vectors))
	}
	for i, v := range file.Vectors {
		if got := DeviceCode(unhex(t, v.InviterKey), unhex(t, v.NewKey), unhex(t, v.PairBinding)); got != v.Code {
			t.Errorf("vector %d: %s, want %s", i, got, v.Code)
		}
	}
	c := file.Confirm
	got := bytes.Join(DeviceConfirmParts(unhex(t, c.SessionBinding), c.InviteID, unhex(t, c.NewKey), unhex(t, c.PairBinding)), nil)
	if !bytes.Equal(got, unhex(t, c.SignatureInput)) {
		t.Fatalf("confirm input %x", got)
	}
}

// devicesHarness serves the account operations and the three device ops.
func newDevicesHarness(t *testing.T) *accountsHarness {
	t.Helper()
	h := newAccountsHarness(t, nil)
	h.listener.cfg.Operations[PurposeSession] = DeviceOperations(DevicesConfig{
		Store: h.store, ServerKey: h.identity.PublicKey(), Logger: h.listener.cfg.Logger,
		Reload: func(ctx context.Context) error { _, err := h.watcher.Poll(ctx); return err },
	})
	return h
}

// member adds an approved device with a real key for subject's user.
func (h *accountsHarness) member(subject string) (accounts.Device, *device) {
	h.t.Helper()
	ctx := context.Background()
	user, _, err := h.store.EnsureUser(ctx, "apple", subject, "")
	if err != nil {
		h.t.Fatal(err)
	}
	d := newDevice(h.t)
	row, err := h.store.AddDevice(ctx, user.ID, "Mac", d.public, "")
	if err != nil {
		h.t.Fatal(err)
	}
	_ = h.store.SetUserState(ctx, user.ID, accounts.UserApproved, accounts.AdminActor("test"))
	if err := h.store.SetDeviceState(ctx, row.ID, accounts.DeviceApproved, accounts.AdminActor("test")); err != nil {
		h.t.Fatal(err)
	}
	return row, d
}

// session opens a session channel for an approved device.
func (h *accountsHarness) session(deviceID int64) *testClient {
	h.t.Helper()
	token, _, err := h.store.IssueAccess(context.Background(), deviceID)
	if err != nil {
		h.t.Fatal(err)
	}
	h.poll()
	c, first := h.hello(PurposeSession, token)
	if first.MessageType() != "ready" {
		h.t.Fatalf("%#v", first)
	}
	return c
}

func (h *accountsHarness) invite(c *testClient, op int64) DeviceInviteReply {
	h.t.Helper()
	c.send(DeviceInvite{Op: op})
	reply, ok := c.recv().(DeviceInviteReply)
	if !ok || reply.Op != op {
		h.t.Fatalf("%#v", reply)
	}
	return reply
}

// pairInvited redeems an invite on a fresh enroll channel and returns the
// new device, the reply and that channel's binding.
func (h *accountsHarness) pairInvited(token string) (*device, Enrolled, []byte) {
	h.t.Helper()
	d := newDevice(h.t)
	c, reply := h.sendPair(token, d)
	return d, enrolled(h.t, reply, "pending"), c.channel.Binding()
}

func confirmMessage(t *testing.T, signer *device, sessionBinding []byte, op, inviteID int64, accept bool, newKey, pairBinding []byte) DeviceConfirm {
	return DeviceConfirm{Op: op, InviteID: inviteID, Accept: accept,
		Signature: signer.sign(t, DeviceConfirmParts(sessionBinding, inviteID, newKey, pairBinding)...)}
}

func (h *accountsHarness) deviceState(id int64) accounts.DeviceState {
	h.t.Helper()
	d, err := h.store.Device(context.Background(), id)
	if err != nil {
		h.t.Fatal(err)
	}
	return d.State
}

// Invite, pair to pending, list with the invite, confirm with a good signature.
func TestDeviceInviteAndConfirm(t *testing.T) {
	h := newDevicesHarness(t)
	inviterRow, inviter := h.member("anna")
	c := h.session(inviterRow.ID)

	reply := h.invite(c, 1)
	if !strings.HasPrefix(reply.PairingToken, "lfp_") || reply.ExpiresAt != WireTime(h.clock.Now().Add(accounts.InviteLifetime)) {
		t.Fatalf("%+v", reply)
	}

	newcomer, e, pairBinding := h.pairInvited(reply.PairingToken)
	if !bytes.Equal(e.InviterDeviceKey, inviter.public) || e.ConfirmBy != WireTime(h.clock.Now().Add(accounts.InviteConfirmWindow)) {
		t.Fatalf("%+v", e)
	}
	code := DeviceCode(e.InviterDeviceKey, newcomer.public, pairBinding)

	c.send(AccountDevices{Op: 2, Action: "list"})
	list, ok := c.recv().(AccountDevicesReply)
	if !ok || len(list.Devices) != 2 {
		t.Fatalf("%#v", list)
	}
	self, pending := list.Devices[0], list.Devices[1]
	if !self.ThisDevice || !self.Connected || self.State != "approved" || self.Invite != nil {
		t.Fatalf("%+v", self)
	}
	i := pending.Invite
	if pending.State != "pending" || pending.ThisDevice || i == nil || i.InviteID != reply.InviteID ||
		!bytes.Equal(i.DeviceKey, newcomer.public) || !bytes.Equal(i.PairBinding, pairBinding) || i.ConfirmBy != e.ConfirmBy {
		t.Fatalf("%+v %+v", pending, i)
	}
	if DeviceCode(inviter.public, i.DeviceKey, i.PairBinding) != code {
		t.Fatal("the two devices show different codes")
	}

	c.send(confirmMessage(t, inviter, c.channel.Binding(), 3, i.InviteID, true, i.DeviceKey, i.PairBinding))
	if got, ok := c.recv().(DeviceConfirmReply); !ok || got.Op != 3 || got.State != "approved" {
		t.Fatalf("%#v", got)
	}
	if h.deviceState(pending.ID) != accounts.DeviceApproved {
		t.Fatal("device not approved")
	}
	h.session(pending.ID)

	logs := h.logs.String()
	if strings.Contains(logs, "lfp_") || strings.Contains(logs, code) || !strings.Contains(logs, "op=device_confirm") {
		t.Fatalf("device log: %s", logs)
	}
	if got := auditActions(t, h.store); !slices.ContainsFunc(got, func(s string) bool { return strings.HasPrefix(s, "invite_confirm ") }) {
		t.Fatalf("invite_confirm missing from %v", got)
	}
}

// A confirmation signed over another channel's binding, or sent by another
// device of the same user, is unauthorized and leaves the device pending; a
// decline removes it; a confirmation after confirm_by is pairing_token_invalid.
func TestDeviceConfirmRefusals(t *testing.T) {
	h := newDevicesHarness(t)
	inviterRow, inviter := h.member("anna")
	siblingRow, sibling := h.member("anna")
	c := h.session(inviterRow.ID)
	other := h.session(inviterRow.ID)

	reply := h.invite(c, 1)
	newcomer, _, pairBinding := h.pairInvited(reply.PairingToken)
	pending, err := h.store.DeviceByKey(context.Background(), newcomer.public)
	if err != nil {
		t.Fatal(err)
	}

	c.send(confirmMessage(t, inviter, other.channel.Binding(), 2, reply.InviteID, true, newcomer.public, pairBinding))
	expectError(t, c.recv(), 2, CodeUnauthorized)

	s := h.session(siblingRow.ID)
	s.send(confirmMessage(t, sibling, s.channel.Binding(), 1, reply.InviteID, true, newcomer.public, pairBinding))
	expectError(t, s.recv(), 1, CodeUnauthorized)
	if h.deviceState(pending.ID) != accounts.DevicePending {
		t.Fatal("a refused confirmation changed the device")
	}

	c = h.session(inviterRow.ID)
	c.send(confirmMessage(t, inviter, c.channel.Binding(), 3, reply.InviteID, false, newcomer.public, pairBinding))
	if got, ok := c.recv().(DeviceConfirmReply); !ok || got.State != "removed" {
		t.Fatalf("%#v", got)
	}
	if _, err := h.store.DeviceByKey(context.Background(), newcomer.public); err == nil {
		t.Fatal("declined device still enrolled")
	}

	reply = h.invite(c, 4)
	late, _, lateBinding := h.pairInvited(reply.PairingToken)
	h.clock.Advance(accounts.InviteConfirmWindow + time.Second)
	c = h.session(inviterRow.ID)
	c.send(confirmMessage(t, inviter, c.channel.Binding(), 1, reply.InviteID, true, late.public, lateBinding))
	expectError(t, c.recv(), 1, CodePairingTokenInvalid)
}

// The fourth open invite for one user is busy.
func TestDeviceInviteLimit(t *testing.T) {
	h := newDevicesHarness(t)
	for i := range accounts.MaxOpenInvitesPerUser + 1 {
		row, _ := h.member("anna")
		c := h.session(row.ID)
		c.send(DeviceInvite{Op: 1})
		m := c.recv()
		if i < accounts.MaxOpenInvitesPerUser {
			if _, ok := m.(DeviceInviteReply); !ok {
				t.Fatalf("%d: %#v", i, m)
			}
			continue
		}
		expectError(t, m, 1, CodeBusy)
	}
}

// Revoking another user's device is unauthorized and audited; revoking the
// caller itself answers with the list, then the channel closes.
func TestAccountDevicesRevoke(t *testing.T) {
	h := newDevicesHarness(t)
	callerRow, _ := h.member("anna")
	strangerRow, _ := h.member("bob")
	c := h.session(callerRow.ID)

	c.send(AccountDevices{Op: 1, Action: "revoke", DeviceID: strangerRow.ID})
	expectError(t, c.recv(), 1, CodeUnauthorized)
	if h.deviceState(strangerRow.ID) != accounts.DeviceApproved {
		t.Fatal("another user's device revoked")
	}
	got := auditActions(t, h.store)
	if !strings.HasPrefix(got[len(got)-1], "cross_user_attempt device:"+strconv.FormatInt(callerRow.ID, 10)) {
		t.Fatal(got)
	}

	c.send(AccountDevices{Op: 2, Action: "revoke", DeviceID: callerRow.ID})
	list, ok := c.recv().(AccountDevicesReply)
	if !ok || list.Op != 2 || len(list.Devices) != 0 {
		t.Fatalf("%#v", list)
	}
	if e, ok := c.recv().(ErrorMessage); !ok || e.Code != CodeRevoked {
		t.Fatalf("%#v", e)
	}
	c.closed()
	if h.deviceState(callerRow.ID) != accounts.DeviceRevoked {
		t.Fatal("not revoked")
	}
}

// A server without the device operations answers not_offered.
func TestDeviceOperationsNotOffered(t *testing.T) {
	h := newAccountsHarness(t, nil)
	h.listener.cfg.Operations[PurposeSession] = map[string]OperationStart{
		"account_devices": DeviceOperations(DevicesConfig{Store: h.store, Logger: log.New(h.logs, "", 0)})["account_devices"],
	}
	row, _ := h.member("anna")
	c := h.session(row.ID)
	c.send(DeviceInvite{Op: 1})
	expectError(t, c.recv(), 1, CodeNotOffered)
}
