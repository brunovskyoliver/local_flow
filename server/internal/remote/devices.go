package remote

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"log"

	"localflow/server/internal/accounts"
)

// Device invite labels (specs/028-server-users-and-rewrite-warmup/contracts/device-invites.md).
const (
	DeviceCodeLabel    = "localflow-v1-device-code"
	DeviceConfirmLabel = "localflow-v1-device-confirm"
)

// DeviceCode is the 6-digit code both devices show for an invite: the first 4
// bytes of SHA-256(label ‖ inviter key ‖ new key ‖ pair binding) as a
// big-endian integer mod 1,000,000, with leading zeros. Test vectors:
// fixtures/remote/device-code.json.
func DeviceCode(inviterKey, newKey, pairBinding []byte) string {
	h := sha256.New()
	for _, part := range [][]byte{[]byte(DeviceCodeLabel), inviterKey, newKey, pairBinding} {
		h.Write(part)
	}
	return fmt.Sprintf("%06d", binary.BigEndian.Uint32(h.Sum(nil)[:4])%1_000_000)
}

// DeviceConfirmParts are what device_confirm's signature covers, in order:
// the label, the inviting device's own session channel binding, the invite ID
// as 8 bytes big-endian, the new device's key and the pair binding.
func DeviceConfirmParts(sessionBinding []byte, inviteID int64, newKey, pairBinding []byte) [][]byte {
	return [][]byte{[]byte(DeviceConfirmLabel), sessionBinding, binary.BigEndian.AppendUint64(nil, uint64(inviteID)), newKey, pairBinding}
}

// DevicesConfig configures the device_invite, device_confirm and
// account_devices session operations.
type DevicesConfig struct {
	Store *accounts.Store
	// ServerKey is the identity's public key, which every pairing token carries.
	ServerKey []byte
	// Reload makes the listener's snapshot see a write at once (the watcher's
	// Poll), so a confirmed device opens sessions and a revoked one's channels
	// close without waiting for the poll. May be nil.
	Reload func(ctx context.Context) error
	Logger *log.Logger
}

// DeviceOperations returns the three session operations by name. Each is
// scoped to the channel's principal; no message names a user.
func DeviceOperations(cfg DevicesConfig) map[string]OperationStart {
	if cfg.Logger == nil {
		cfg.Logger = log.New(discard{}, "", 0)
	}
	d := &deviceOps{cfg}
	return map[string]OperationStart{"device_invite": d.invite, "device_confirm": d.confirm, "account_devices": d.devices}
}

type deviceOps struct{ cfg DevicesConfig }

func (d *deviceOps) reload(ctx context.Context) {
	if d.cfg.Reload != nil {
		_ = d.cfg.Reload(ctx)
	}
}

// begin checks the session and the caller's approval in the snapshot.
func (d *deviceOps) begin(c *Conn) (accounts.Principal, error) {
	if err := checkAccess(c); err != nil {
		return accounts.Principal{}, err
	}
	p := c.Principal()
	if !c.listener.cfg.Accounts.Snapshot().Approved(p.UserID, p.DeviceID) {
		return p, &Error{CodeNotApproved, "device not approved"}
	}
	return p, nil
}

// log writes IDs and codes only: never tokens, codes shown to people, keys or
// bindings.
func (d *deviceOps) log(c *Conn, op string, p accounts.Principal, target int64, code ErrorCode) {
	d.cfg.Logger.Printf("remote channel=%d op=%s user=%d device=%d target=%d code=%s", c.ID(), op, p.UserID, p.DeviceID, target, code)
}

func storeCode(err error) ErrorCode {
	switch {
	case errors.Is(err, accounts.ErrInviteLimit):
		return CodeBusy
	case errors.Is(err, accounts.ErrNotApproved):
		return CodeNotApproved
	case errors.Is(err, accounts.ErrUnauthorized):
		return CodeUnauthorized
	case errors.Is(err, accounts.ErrPairingTokenInvalid):
		return CodePairingTokenInvalid
	}
	return CodeInternal
}

// invite: a 10-minute, single-use pairing token for the caller's own user.
func (d *deviceOps) invite(ctx context.Context, c *Conn, m Message) (Operation, error) {
	message, ok := m.(DeviceInvite)
	if !ok {
		return nil, invalid("expected device_invite")
	}
	p, err := d.begin(c)
	if err != nil {
		return nil, err
	}
	token, row, err := d.cfg.Store.CreateInvite(ctx, d.cfg.ServerKey, p.DeviceID)
	if err != nil {
		code := storeCode(err)
		d.log(c, "device_invite", p, 0, code)
		return nil, &Error{code, "invite refused"}
	}
	d.log(c, "device_invite", p, row.ID, "ok")
	d.reload(ctx)
	return nil, c.Send(ctx, DeviceInviteReply{Op: message.Op, InviteID: row.ID, PairingToken: token, ExpiresAt: WireTime(row.ExpiresAt)})
}

// confirm: the inviting device approves or removes the device that redeemed
// its invite, with a signature by its stored device key over this channel's
// binding, so a captured confirmation can't be replayed elsewhere.
func (d *deviceOps) confirm(ctx context.Context, c *Conn, m Message) (Operation, error) {
	message, ok := m.(DeviceConfirm)
	if !ok {
		return nil, invalid("expected device_confirm")
	}
	p, err := d.begin(c)
	if err != nil {
		return nil, err
	}
	binding := c.Binding()
	state, err := d.cfg.Store.ConfirmInvite(ctx, p.DeviceID, message.InviteID, message.Accept, func(callerKey, newKey, pairBinding []byte) bool {
		return verifyDeviceSignature(callerKey, message.Signature, DeviceConfirmParts(binding, message.InviteID, newKey, pairBinding)...)
	})
	if err != nil {
		code := storeCode(err)
		d.log(c, "device_confirm", p, message.InviteID, code)
		return nil, &Error{code, "confirmation refused"}
	}
	d.log(c, "device_confirm", p, message.InviteID, "ok")
	d.reload(ctx)
	reply := "approved"
	if state != accounts.DeviceApproved {
		reply = "removed"
	}
	return nil, c.Send(ctx, DeviceConfirmReply{Op: message.Op, State: reply})
}

// devices lists the caller's user's devices or revokes one of them. A revoke
// answers with the updated list before the snapshot reload closes the revoked
// device's channels, so revoking the caller itself still gets its reply.
func (d *deviceOps) devices(ctx context.Context, c *Conn, m Message) (Operation, error) {
	message, ok := m.(AccountDevices)
	if !ok {
		return nil, invalid("expected account_devices")
	}
	p, err := d.begin(c)
	if err != nil {
		return nil, err
	}
	if message.Action == "revoke" {
		if err := d.cfg.Store.RevokeAccountDevice(ctx, p.DeviceID, message.DeviceID); err != nil {
			code := storeCode(err)
			d.log(c, "account_devices.revoke", p, message.DeviceID, code)
			return nil, &Error{code, "revoke refused"}
		}
		d.log(c, "account_devices.revoke", p, message.DeviceID, "ok")
		defer d.reload(ctx)
	}
	list, err := d.cfg.Store.AccountDevices(ctx, p.DeviceID)
	if err != nil {
		return nil, &Error{CodeInternal, "account devices"}
	}
	devices := make([]AccountDevice, 0, len(list))
	for _, row := range list {
		device := AccountDevice{ID: row.ID, Name: row.Name, State: string(row.State), EnrolledAt: WireTime(row.EnrolledAt),
			Connected: len(c.listener.registry.Device(row.ID)) > 0, ThisDevice: row.ID == p.DeviceID}
		if row.Kind != accounts.KindUnknown {
			kind := string(row.Kind)
			device.Kind = &kind
		}
		if !row.LastSeenAt.IsZero() {
			seen := WireTime(row.LastSeenAt)
			device.LastSeenAt = &seen
		}
		if i := row.Invite; i != nil {
			device.Invite = &PendingInvite{InviteID: i.InviteID, DeviceKey: i.DeviceKey, PairBinding: i.PairBinding, ConfirmBy: WireTime(i.ConfirmBy)}
		}
		devices = append(devices, device)
	}
	return nil, c.Send(ctx, AccountDevicesReply{Op: message.Op, Devices: devices})
}
