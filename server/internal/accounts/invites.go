package accounts

import (
	"context"
	"database/sql"
	"errors"
	"strconv"
	"time"
)

// Device invites (ADR 0039, specs/028-server-users-and-rewrite-warmup/
// contracts/device-invites.md): an approved device asks for a pairing token for
// its own user, the redeeming device becomes pending, and the inviting device
// confirms it with its device key. Limits are checked in the creating
// transaction.
const (
	InviteLifetime          = 10 * time.Minute
	InviteConfirmWindow     = 10 * time.Minute
	MaxOpenInvitesPerUser   = 3
	MaxInvitesPerDeviceHour = 10
	MaxAccountDevices       = 100
	PairingAwaitingConfirm  = PairingState("awaiting_confirm")
	PairingDeclined         = PairingState("declined")
)

// ErrInviteLimit is past one of the invite limits (or the live token cap); the
// operation answers busy.
var ErrInviteLimit = errors.New("accounts: invite limit reached")

// CreateInvite issues a 10-minute, single-use invite for deviceID's own user and
// returns its value, which exists nowhere else afterwards. The device and its
// user must be approved (ErrNotApproved). It revokes the device's earlier live
// invite, then refuses with ErrInviteLimit past 3 open invites for the user, 10
// created by the device in the last hour or the server's live token cap. Audit
// invite_create, actor device:<id>.
func (s *Store) CreateInvite(ctx context.Context, serverKey []byte, deviceID int64) (string, PairingToken, error) {
	token, hash, err := NewPairingToken(serverKey)
	if err != nil {
		return "", PairingToken{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", PairingToken{}, err
	}
	defer tx.Rollback()
	now := s.millis()
	if err := expireInvites(ctx, tx, now); err != nil {
		return "", PairingToken{}, err
	}
	cutoff := now - pairingRetention.Milliseconds()
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_tokens
		WHERE (state = 'live' AND expires_at < ?) OR (state NOT IN ('live', 'awaiting_confirm') AND changed_at < ?)`, cutoff, cutoff); err != nil {
		return "", PairingToken{}, err
	}
	var userID int64
	var deviceState, userState string
	switch err := tx.QueryRowContext(ctx, `SELECT d.user_id, d.state, u.state FROM devices d JOIN users u ON u.id = d.user_id WHERE d.id = ?`, deviceID).
		Scan(&userID, &deviceState, &userState); {
	case errors.Is(err, sql.ErrNoRows):
		return "", PairingToken{}, ErrNotApproved
	case err != nil:
		return "", PairingToken{}, err
	case DeviceState(deviceState) != DeviceApproved || UserState(userState) != UserApproved:
		return "", PairingToken{}, ErrNotApproved
	}
	actor := DeviceActor(deviceID)
	if err := revokeLiveInvites(ctx, tx, now, actor, `inviter_device_id = ?`, deviceID); err != nil {
		return "", PairingToken{}, err
	}
	var open, recent, live int
	if err := tx.QueryRowContext(ctx, `SELECT
		(SELECT count(*) FROM pairing_tokens WHERE purpose = 'invite' AND user_id = ?1
			AND ((state = 'live' AND expires_at > ?2) OR state = 'awaiting_confirm')),
		(SELECT count(*) FROM pairing_tokens WHERE purpose = 'invite' AND inviter_device_id = ?3 AND created_at > ?2 - ?4),
		(SELECT count(*) FROM pairing_tokens WHERE state = 'live' AND expires_at > ?2)`,
		userID, now, deviceID, time.Hour.Milliseconds()).Scan(&open, &recent, &live); err != nil {
		return "", PairingToken{}, err
	}
	if open >= MaxOpenInvitesPerUser || recent >= MaxInvitesPerDeviceHour || live >= MaxLivePairingTokens {
		return "", PairingToken{}, ErrInviteLimit
	}
	expires := now + InviteLifetime.Milliseconds()
	label := "Invite from device " + strconv.FormatInt(deviceID, 10)
	result, err := tx.ExecContext(ctx, `INSERT INTO pairing_tokens (label, hash, user_id, state, created_at, expires_at, changed_at, created_by, purpose, inviter_device_id)
		VALUES (?, ?, ?, 'live', ?, ?, ?, ?, 'invite', ?)`, label, hash[:], userID, now, expires, now, actor, deviceID)
	if err != nil {
		return "", PairingToken{}, err
	}
	id, _ := result.LastInsertId()
	if err := insertAudit(ctx, tx, now, AuditEntry{Actor: actor, Action: "invite_create", Target: TokenTarget(id), Outcome: "ok"}); err != nil {
		return "", PairingToken{}, err
	}
	if err := tx.Commit(); err != nil {
		return "", PairingToken{}, err
	}
	return token, PairingToken{ID: id, Label: label, State: PairingLive, UserID: userID, CreatedAt: time.UnixMilli(now),
		ExpiresAt: time.UnixMilli(expires), ChangedAt: time.UnixMilli(now), CreatedBy: actor}, nil
}

// revokeLiveInvites moves the live invites matching where to revoked and
// audits token_revoke for each.
func revokeLiveInvites(ctx context.Context, tx *sql.Tx, now int64, actor, where string, args ...any) error {
	ids, err := tokenIDs(ctx, tx, `SELECT id FROM pairing_tokens WHERE purpose = 'invite' AND state = 'live' AND `+where, args...)
	if err != nil {
		return err
	}
	for _, id := range ids {
		if _, err := tx.ExecContext(ctx, `UPDATE pairing_tokens SET state = 'revoked', changed_at = ? WHERE id = ?`, now, id); err != nil {
			return err
		}
		if err := insertAudit(ctx, tx, now, AuditEntry{Actor: actor, Action: "token_revoke", Target: TokenTarget(id), Outcome: "ok"}); err != nil {
			return err
		}
	}
	return nil
}

// declineInvites moves the awaiting_confirm invites matching where to declined,
// deletes their pending devices and audits action for each. device_key stays,
// so a retry by the same key is answered pairing_token_invalid.
func declineInvites(ctx context.Context, tx *sql.Tx, now int64, actor, action, where string, args ...any) error {
	rows, err := tx.QueryContext(ctx, `SELECT id, device_id FROM pairing_tokens WHERE state = 'awaiting_confirm' AND `+where, args...)
	if err != nil {
		return err
	}
	type pending struct{ token, device int64 }
	var found []pending
	for rows.Next() {
		var p pending
		var device sql.NullInt64
		if err := rows.Scan(&p.token, &device); err != nil {
			rows.Close()
			return err
		}
		p.device = device.Int64
		found = append(found, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, p := range found {
		if _, err := tx.ExecContext(ctx, `UPDATE pairing_tokens SET state = 'declined', device_id = NULL, changed_at = ? WHERE id = ?`, now, p.token); err != nil {
			return err
		}
		// Only a still-pending device: one an administrator approved meanwhile
		// moved the token to redeemed and is not here.
		if _, err := tx.ExecContext(ctx, `DELETE FROM devices WHERE id = ? AND state = 'pending'`, p.device); err != nil {
			return err
		}
		if err := insertAudit(ctx, tx, now, AuditEntry{Actor: actor, Action: action, Target: TokenTarget(p.token), Outcome: "ok"}); err != nil {
			return err
		}
	}
	return nil
}

func tokenIDs(ctx context.Context, tx *sql.Tx, query string, args ...any) ([]int64, error) {
	rows, err := tx.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// expireInvites declines every invite whose confirmation deadline has passed.
func expireInvites(ctx context.Context, tx *sql.Tx, now int64) error {
	return declineInvites(ctx, tx, now, SystemActor, "invite_expire", `confirm_by <= ?`, now)
}

// ExpireInvites moves awaiting_confirm invites past their deadline to declined
// and deletes their pending devices (audit invite_expire, actor system). flowd
// calls it at most once a minute; the invite operations sweep first anyway.
func (s *Store) ExpireInvites(ctx context.Context) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := expireInvites(ctx, tx, s.millis()); err != nil {
		return err
	}
	return tx.Commit()
}

// cascadeDeviceRevoke runs in the transaction that revokes deviceID: its live
// invites are revoked, the invites it is waiting to confirm are declined (their
// pending devices deleted), and when deviceID is itself a pending invited
// device its invite is declined and the row deleted, reported as deleted.
func cascadeDeviceRevoke(ctx context.Context, tx *sql.Tx, now int64, actor string, deviceID int64) (deleted bool, err error) {
	if err := revokeLiveInvites(ctx, tx, now, actor, `inviter_device_id = ?`, deviceID); err != nil {
		return false, err
	}
	if err := declineInvites(ctx, tx, now, actor, "invite_decline", `inviter_device_id = ?`, deviceID); err != nil {
		return false, err
	}
	var invited int
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM pairing_tokens WHERE state = 'awaiting_confirm' AND device_id = ?`, deviceID).Scan(&invited); err != nil {
		return false, err
	}
	if invited == 0 {
		return false, nil
	}
	return true, declineInvites(ctx, tx, now, actor, "invite_decline", `device_id = ?`, deviceID)
}

// cascadeUserRevoke revokes every live invite of userID and declines every
// invite awaiting confirmation, deleting the pending devices.
func cascadeUserRevoke(ctx context.Context, tx *sql.Tx, now int64, actor string, userID int64) error {
	if err := revokeLiveInvites(ctx, tx, now, actor, `user_id = ?`, userID); err != nil {
		return err
	}
	return declineInvites(ctx, tx, now, actor, "invite_decline", `user_id = ?`, userID)
}

// ConfirmInvite answers an invite the caller created: verify checks the
// device_confirm signature with the caller's stored key, the new device's key
// and the pair binding. accept approves the pending device and marks the
// invite redeemed (audit invite_confirm); otherwise the device is deleted and
// the invite declined (invite_decline). It returns the new device's state:
// approved, or revoked for removed.
//
// An unknown invite, one another device created, or a bad signature is
// ErrUnauthorized; an invite not awaiting confirmation, or past its deadline,
// ErrPairingTokenInvalid; a caller no longer approved, ErrNotApproved.
func (s *Store) ConfirmInvite(ctx context.Context, callerID, inviteID int64, accept bool,
	verify func(callerKey, newKey, pairBinding []byte) bool) (DeviceState, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	now := s.millis()
	if err := expireInvites(ctx, tx, now); err != nil {
		return "", err
	}
	var state, deviceState, userState string
	var newDevice sql.NullInt64
	var newKey, binding, callerKey []byte
	err = tx.QueryRowContext(ctx, `SELECT t.state, t.device_id, t.device_key, t.pair_binding, d.public_key, d.state, u.state
		FROM pairing_tokens t JOIN devices d ON d.id = t.inviter_device_id JOIN users u ON u.id = d.user_id
		WHERE t.id = ? AND t.purpose = 'invite' AND t.inviter_device_id = ?`, inviteID, callerID).
		Scan(&state, &newDevice, &newKey, &binding, &callerKey, &deviceState, &userState)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return "", ErrUnauthorized
	case err != nil:
		return "", err
	case DeviceState(deviceState) != DeviceApproved || UserState(userState) != UserApproved:
		return "", ErrNotApproved
	case PairingState(state) != PairingAwaitingConfirm:
		// A sweep above may have declined it in this transaction; keep that.
		if err := tx.Commit(); err != nil {
			return "", err
		}
		return "", ErrPairingTokenInvalid
	case !verify(callerKey, newKey, binding):
		return "", ErrUnauthorized
	}
	actor := DeviceActor(callerID)
	if !accept {
		if err := declineInvites(ctx, tx, now, actor, "invite_decline", `id = ?`, inviteID); err != nil {
			return "", err
		}
		return DeviceRevoked, tx.Commit()
	}
	if _, err := tx.ExecContext(ctx, `UPDATE devices SET state = 'approved', changed_at = ? WHERE id = ? AND state = 'pending'`, now, newDevice.Int64); err != nil {
		return "", err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE pairing_tokens SET state = 'redeemed', changed_at = ? WHERE id = ?`, now, inviteID); err != nil {
		return "", err
	}
	if err := insertAudit(ctx, tx, now, AuditEntry{Actor: actor, Action: "invite_confirm", Target: TokenTarget(inviteID), Outcome: "ok"}); err != nil {
		return "", err
	}
	return DeviceApproved, tx.Commit()
}

// PendingInvite is what the inviting device needs to show the code and sign
// the confirmation of a device that redeemed its invite.
type PendingInvite struct {
	InviteID    int64
	DeviceKey   []byte
	PairBinding []byte
	ConfirmBy   time.Time
}

// AccountDevice is one row of "Your devices". Invite is set only on a pending
// device that redeemed an invite the caller created.
type AccountDevice struct {
	Device
	Invite *PendingInvite
}

// AccountDevices lists the caller's own user's devices that are not revoked,
// at most MaxAccountDevices, by id, after sweeping expired invites. The
// operation checks the caller's approval before calling it; the list after the
// caller revoked itself is still its user's.
func (s *Store) AccountDevices(ctx context.Context, callerID int64) ([]AccountDevice, error) {
	if err := s.ExpireInvites(ctx); err != nil {
		return nil, err
	}
	caller, err := s.Device(ctx, callerID)
	if err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx, deviceColumns+` WHERE user_id = ? AND state != 'revoked' ORDER BY id LIMIT ?`, caller.UserID, MaxAccountDevices)
	if err != nil {
		return nil, err
	}
	var list []AccountDevice
	for rows.Next() {
		device, err := scanDevice(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		list = append(list, AccountDevice{Device: device})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := range list {
		if list[i].State != DevicePending {
			continue
		}
		var invite PendingInvite
		var confirmBy int64
		err := s.db.QueryRowContext(ctx, `SELECT id, device_key, pair_binding, confirm_by FROM pairing_tokens
			WHERE state = 'awaiting_confirm' AND device_id = ? AND inviter_device_id = ?`, list[i].ID, callerID).
			Scan(&invite.InviteID, &invite.DeviceKey, &invite.PairBinding, &confirmBy)
		switch {
		case errors.Is(err, sql.ErrNoRows):
		case err != nil:
			return nil, err
		default:
			invite.ConfirmBy = time.UnixMilli(confirmBy)
			list[i].Invite = &invite
		}
	}
	return list, nil
}

// RevokeAccountDevice revokes targetID, a device of the caller's own user,
// including the caller itself, with the invite cascade of SetDeviceState
// (a pending invited device is deleted and its invite declined). An unknown
// device or one of another user is ErrUnauthorized with a cross_user_attempt
// row; a caller no longer approved is ErrNotApproved. Revoking a device that is
// already revoked changes nothing.
func (s *Store) RevokeAccountDevice(ctx context.Context, callerID, targetID int64) error {
	caller, err := s.Device(ctx, callerID)
	if err != nil {
		return err
	}
	if caller.State != DeviceApproved {
		return ErrNotApproved
	}
	actor := DeviceActor(callerID)
	// user_id never changes, so this check outside the transaction holds.
	target, err := s.Device(ctx, targetID)
	switch {
	case err != nil && !errors.Is(err, ErrNotFound):
		return err
	case err != nil || target.UserID != caller.UserID:
		if err := s.Audit(ctx, AuditEntry{Actor: actor, Action: "cross_user_attempt", Target: UserTarget(caller.UserID), Outcome: "unauthorized"}); err != nil {
			return err
		}
		return ErrUnauthorized
	case target.State == DeviceRevoked:
		return nil
	}
	err = s.SetDeviceState(ctx, targetID, DeviceRevoked, actor)
	if errors.Is(err, ErrNotFound) { // deleted meanwhile by a decline or the sweep
		return nil
	}
	return err
}

// Inviters maps each device that redeemed an invite to the device that created
// it, for flowd admin list --json. A declined invite has no device left.
func (s *Store) Inviters(ctx context.Context) (map[int64]int64, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT device_id, inviter_device_id FROM pairing_tokens
		WHERE purpose = 'invite' AND device_id IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	inviters := map[int64]int64{}
	for rows.Next() {
		var device, inviter int64
		if err := rows.Scan(&device, &inviter); err != nil {
			return nil, err
		}
		inviters[device] = inviter
	}
	return inviters, rows.Err()
}
