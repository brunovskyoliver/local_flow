package accounts

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"strconv"
	"time"
)

// Pairing tokens (specs/027-remote-pairing, ADR 0037): the prefix, then base64url
// without padding of the server's public key and 32 random bytes, so that holding
// a token authenticates the server. Only HashToken of the string is stored.
const (
	PairingPrefix          = "lfp_"
	DefaultPairingLifetime = 24 * time.Hour
	MaxLivePairingTokens   = 100
	pairingRetention       = 90 * 24 * time.Hour
	serverKeyBytes         = 32
)

// PairingState is a stored state or, in listings only, the derived expired.
type PairingState string

const (
	PairingLive     PairingState = "live"
	PairingRedeemed PairingState = "redeemed"
	PairingRevoked  PairingState = "revoked"
	PairingExpired  PairingState = "expired"
)

var (
	// ErrPairingTokenInvalid answers unknown, expired, revoked and spent tokens
	// alike, so a holder learns nothing about which tokens exist.
	ErrPairingTokenInvalid = errors.New("accounts: pairing token not accepted")
	ErrPairingTokenLimit   = errors.New("accounts: live pairing token limit reached")
)

// PairingToken is one row of pairing_tokens without its hash or redeeming key.
// UserID 0 before redemption means the token creates a new user.
type PairingToken struct {
	ID        int64
	Label     string
	State     PairingState
	UserID    int64
	DeviceID  int64
	CreatedAt time.Time
	ExpiresAt time.Time
	ChangedAt time.Time
	CreatedBy string
}

// Pairing is the result of a redemption. The caller sends Refresh to the client.
type Pairing struct {
	TokenID          int64
	UserID           int64
	DeviceID         int64
	Refresh          string
	RefreshExpiresAt time.Time
}

// NewPairingToken returns a fresh token for the server's 32-byte public key, and
// its hash.
func NewPairingToken(serverKey []byte) (string, [32]byte, error) {
	if len(serverKey) != serverKeyBytes {
		return "", [32]byte{}, ErrInvalidRecord
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", [32]byte{}, err
	}
	token := PairingPrefix + base64.RawURLEncoding.EncodeToString(append(bytes.Clone(serverKey), raw...))
	return token, HashToken(token), nil
}

// CreatePairingToken issues a token and returns its value, which exists nowhere
// else afterwards. userID 0 targets a new user; otherwise the user must be
// approved, because issuing counts as approval of a device and a token can't
// approve the user itself. It first deletes redeemed, revoked and expired rows
// older than 90 days. lifetime is 1 h, 24 h or 7 d.
func (s *Store) CreatePairingToken(ctx context.Context, serverKey []byte, label string, userID int64, lifetime time.Duration, actor string) (string, PairingToken, error) {
	if len(label) == 0 || len(label) > maxNameBytes || hasControl(label) || !adminPattern.MatchString(actor) ||
		(lifetime != time.Hour && lifetime != DefaultPairingLifetime && lifetime != 7*24*time.Hour) {
		return "", PairingToken{}, ErrInvalidRecord
	}
	token, hash, err := NewPairingToken(serverKey)
	if err != nil {
		return "", PairingToken{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", PairingToken{}, err
	}
	defer tx.Rollback()
	now := s.now().UnixMilli()
	cutoff := now - pairingRetention.Milliseconds()
	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_tokens
		WHERE (state = 'live' AND expires_at < ?) OR (state != 'live' AND changed_at < ?)`, cutoff, cutoff); err != nil {
		return "", PairingToken{}, err
	}
	var live int
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM pairing_tokens WHERE state = 'live' AND expires_at > ?`, now).Scan(&live); err != nil {
		return "", PairingToken{}, err
	}
	if live >= MaxLivePairingTokens {
		return "", PairingToken{}, ErrPairingTokenLimit
	}
	var target any
	if userID != 0 {
		var state string
		switch err := tx.QueryRowContext(ctx, `SELECT state FROM users WHERE id = ?`, userID).Scan(&state); {
		case errors.Is(err, sql.ErrNoRows):
			return "", PairingToken{}, ErrNotFound
		case err != nil:
			return "", PairingToken{}, err
		case UserState(state) != UserApproved:
			return "", PairingToken{}, &TransitionError{Kind: "user", From: state, To: "token target"}
		}
		target = userID
	}
	expires := now + lifetime.Milliseconds()
	result, err := tx.ExecContext(ctx, `INSERT INTO pairing_tokens (label, hash, user_id, state, created_at, expires_at, changed_at, created_by)
		VALUES (?, ?, ?, 'live', ?, ?, ?, ?)`, label, hash[:], target, now, expires, now, actor)
	if err != nil {
		return "", PairingToken{}, err
	}
	id, _ := result.LastInsertId()
	entry := AuditEntry{Actor: actor, Action: "token_create", Target: TokenTarget(id), Outcome: "ok"}
	if err := insertAudit(ctx, tx, now, entry); err != nil {
		return "", PairingToken{}, err
	}
	if err := tx.Commit(); err != nil {
		return "", PairingToken{}, err
	}
	return token, PairingToken{ID: id, Label: label, State: PairingLive, UserID: userID, CreatedAt: time.UnixMilli(now),
		ExpiresAt: time.UnixMilli(expires), ChangedAt: time.UnixMilli(now), CreatedBy: actor}, nil
}

// PairingTokens lists every token by id. A live token past its expiry is listed
// as expired.
func (s *Store) PairingTokens(ctx context.Context) ([]PairingToken, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, label, state, coalesce(user_id, 0), coalesce(device_id, 0), created_at, expires_at, changed_at, created_by
		FROM pairing_tokens ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	now := s.now()
	var tokens []PairingToken
	for rows.Next() {
		var t PairingToken
		var created, expires, changed int64
		if err := rows.Scan(&t.ID, &t.Label, &t.State, &t.UserID, &t.DeviceID, &created, &expires, &changed, &t.CreatedBy); err != nil {
			return nil, err
		}
		t.CreatedAt, t.ExpiresAt, t.ChangedAt = time.UnixMilli(created), time.UnixMilli(expires), time.UnixMilli(changed)
		if t.State == PairingLive && !now.Before(t.ExpiresAt) {
			t.State = PairingExpired
		}
		tokens = append(tokens, t)
	}
	return tokens, rows.Err()
}

// RevokePairingToken moves a live token to revoked and audits it. A redeemed or
// revoked token is a TransitionError; the device a redeemed token created is
// revoked through SetDeviceState.
func (s *Store) RevokePairingToken(ctx context.Context, id int64, actor string) error {
	if !validActor(actor) {
		return ErrInvalidRecord
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var from string
	switch err := tx.QueryRowContext(ctx, `SELECT state FROM pairing_tokens WHERE id = ?`, id).Scan(&from); {
	case errors.Is(err, sql.ErrNoRows):
		return ErrNotFound
	case err != nil:
		return err
	case PairingState(from) != PairingLive:
		return &TransitionError{Kind: "token", From: from, To: string(PairingRevoked)}
	}
	now := s.millis()
	if _, err := tx.ExecContext(ctx, `UPDATE pairing_tokens SET state = 'revoked', changed_at = ? WHERE id = ?`, now, id); err != nil {
		return err
	}
	entry := AuditEntry{Actor: actor, Action: "token_revoke", Target: TokenTarget(id), Outcome: "ok"}
	if err := insertAudit(ctx, tx, now, entry); err != nil {
		return err
	}
	return tx.Commit()
}

// RedeemPairingToken spends a token for a device key that the caller has already
// verified, in one transaction: it creates the token user or finds the target
// user, adds or approves the device, issues a refresh token and marks the token
// redeemed. An error leaves all of that undone and writes only an audit row.
//
// The key that redeemed a token may redeem it again before it expires, because
// the reply can be lost; that starts a new refresh lineage for the same device.
//
// Refusals, with the token left unspent except where it already was:
//   - unknown, expired, revoked, or spent by another key: ErrPairingTokenInvalid
//   - the key's device is revoked, or the target user is: ErrRevoked
//   - the key is enrolled to another user: ErrUnauthorized
//
// kind (may be unknown) is stored on a new device and fills an unknown kind on
// a device the key already has; a stored kind never changes.
func (s *Store) RedeemPairingToken(ctx context.Context, token, deviceName string, deviceKey []byte, kind DeviceKind) (Pairing, error) {
	if len(deviceName) == 0 || len(deviceName) > maxNameBytes || hasControl(deviceName) || len(deviceKey) != publicKeyBytes || deviceKey[0] != 0x04 ||
		!kind.Valid() {
		return Pairing{}, ErrInvalidRecord
	}
	hash := HashToken(token)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Pairing{}, err
	}
	defer tx.Rollback()
	now := s.millis()
	refuse := func(id int64, outcome string, refusal error) (Pairing, error) {
		if id == 0 { // an unknown token: anyone can send these, so no audit row
			return Pairing{}, refusal
		}
		entry := AuditEntry{Actor: SystemActor, Action: "pair", Target: TokenTarget(id), Outcome: outcome}
		if err := insertAudit(ctx, tx, now, entry); err != nil {
			return Pairing{}, err
		}
		if err := tx.Commit(); err != nil {
			return Pairing{}, err
		}
		return Pairing{}, refusal
	}
	invalid := func(id int64) (Pairing, error) { return refuse(id, "pairing_token_invalid", ErrPairingTokenInvalid) }
	revoked := func(id int64) (Pairing, error) { return refuse(id, "revoked", ErrRevoked) }

	var id, expires int64
	var label, state string
	var userID, deviceID sql.NullInt64
	var boundKey []byte
	err = tx.QueryRowContext(ctx, `SELECT id, label, state, user_id, device_id, device_key, expires_at FROM pairing_tokens WHERE hash = ?`, hash[:]).
		Scan(&id, &label, &state, &userID, &deviceID, &boundKey, &expires)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return invalid(0)
	case err != nil:
		return Pairing{}, err
	case now >= expires, PairingState(state) == PairingRevoked:
		return invalid(id)
	}

	var device Device
	if PairingState(state) == PairingRedeemed {
		if !bytes.Equal(boundKey, deviceKey) {
			return invalid(id)
		}
		if device, err = scanDevice(tx.QueryRowContext(ctx, deviceColumns+` WHERE id = ?`, deviceID.Int64)); err != nil {
			return Pairing{}, err
		}
		if device.State == DeviceRevoked {
			return revoked(id)
		}
		var owner string
		if err := tx.QueryRowContext(ctx, `SELECT state FROM users WHERE id = ?`, device.UserID).Scan(&owner); err != nil {
			return Pairing{}, err
		}
		if UserState(owner) == UserRevoked {
			return revoked(id)
		}
	} else {
		device, err = scanDevice(tx.QueryRowContext(ctx, deviceColumns+` WHERE public_key = ?`, deviceKey))
		enrolled := err == nil
		if err != nil && !errors.Is(err, ErrNotFound) {
			return Pairing{}, err
		}
		switch {
		case enrolled && device.State == DeviceRevoked:
			return revoked(id)
		case enrolled && device.UserID != userID.Int64:
			return refuse(id, "unauthorized", ErrUnauthorized)
		}
		if userID.Valid {
			var owner string
			if err := tx.QueryRowContext(ctx, `SELECT state FROM users WHERE id = ?`, userID.Int64).Scan(&owner); err != nil {
				return Pairing{}, err
			}
			switch UserState(owner) {
			case UserApproved:
			case UserRevoked:
				return revoked(id)
			default:
				return refuse(id, "not_approved", ErrNotApproved)
			}
		} else {
			result, err := tx.ExecContext(ctx, `INSERT INTO users (provider, subject, display, state, created_at, changed_at) VALUES ('token', ?, ?, 'approved', ?, ?)`,
				"token:"+strconv.FormatInt(id, 10), label, now, now)
			if err != nil {
				return Pairing{}, err
			}
			userID.Int64, _ = result.LastInsertId()
		}
		switch {
		case !enrolled:
			result, err := tx.ExecContext(ctx, `INSERT INTO devices (user_id, name, kind, public_key, state, enrolled_at, last_seen_at, changed_at) VALUES (?, ?, ?, ?, 'approved', ?, 0, ?)`,
				userID.Int64, deviceName, kind.value(), deviceKey, now, now)
			if err != nil {
				return Pairing{}, err
			}
			device.ID, _ = result.LastInsertId()
			device.UserID = userID.Int64
		case device.State != DeviceApproved:
			if _, err := tx.ExecContext(ctx, `UPDATE devices SET state = 'approved', changed_at = ? WHERE id = ?`, now, device.ID); err != nil {
				return Pairing{}, err
			}
		}
		if _, err := tx.ExecContext(ctx, `UPDATE pairing_tokens SET state = 'redeemed', changed_at = ?, user_id = ?, device_id = ?, device_key = ? WHERE id = ?`,
			now, device.UserID, device.ID, deviceKey, id); err != nil {
			return Pairing{}, err
		}
	}
	if kind != KindUnknown {
		if _, err := tx.ExecContext(ctx, fillKind, string(kind), device.ID); err != nil {
			return Pairing{}, err
		}
	}
	refresh, refreshExpires, err := s.issueRefresh(ctx, tx, device.ID)
	if err != nil {
		return Pairing{}, err
	}
	entry := AuditEntry{Actor: DeviceActor(device.ID), Action: "pair", Target: TokenTarget(id), Outcome: "ok"}
	if err := insertAudit(ctx, tx, now, entry); err != nil {
		return Pairing{}, err
	}
	if err := tx.Commit(); err != nil {
		return Pairing{}, err
	}
	return Pairing{TokenID: id, UserID: device.UserID, DeviceID: device.ID, Refresh: refresh, RefreshExpiresAt: refreshExpires}, nil
}
