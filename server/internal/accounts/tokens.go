package accounts

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"errors"
	"time"
)

// Opaque server tokens (research R5): a prefix plus 32 random bytes in
// base64url without padding. Only SHA-256 of the token string is stored.
const (
	AccessPrefix    = "lfa_"
	RefreshPrefix   = "lfr_"
	AccessLifetime  = 15 * time.Minute
	RefreshLifetime = 30 * 24 * time.Hour
)

var (
	ErrUnauthorized = errors.New("accounts: token not accepted")
	ErrTokenExpired = errors.New("accounts: access token expired")
	ErrNotApproved  = errors.New("accounts: user or device not approved")
	ErrRevoked      = errors.New("accounts: user or device revoked")
	// ErrRefreshReuse means a replaced refresh token was presented; the
	// device has been revoked.
	ErrRefreshReuse = errors.New("accounts: refresh token reused")
)

// NewToken returns a fresh token and its hash.
func NewToken(prefix string) (string, [32]byte, error) {
	if prefix != AccessPrefix && prefix != RefreshPrefix {
		return "", [32]byte{}, errors.New("accounts: unknown token prefix")
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", [32]byte{}, err
	}
	token := prefix + base64.RawURLEncoding.EncodeToString(raw)
	return token, HashToken(token), nil
}

// HashToken is the stored form of a token.
func HashToken(token string) [32]byte { return sha256.Sum256([]byte(token)) }

// Tokens is the result of a successful refresh.
type Tokens struct {
	UserID           int64
	DeviceID         int64
	Access           string
	AccessExpiresAt  time.Time
	Refresh          string
	RefreshExpiresAt time.Time
}

// IssueRefresh starts a device's refresh lineage (enrollment): a new refresh
// token, no previous hash.
func (s *Store) IssueRefresh(ctx context.Context, deviceID int64) (string, time.Time, error) {
	token, hash, err := NewToken(RefreshPrefix)
	if err != nil {
		return "", time.Time{}, err
	}
	expires := s.now().Add(RefreshLifetime)
	result, err := s.db.ExecContext(ctx, `UPDATE devices SET refresh_hash = ?, previous_refresh_hash = NULL, refresh_expires_at = ? WHERE id = ?`,
		hash[:], expires.UnixMilli(), deviceID)
	if err != nil {
		return "", time.Time{}, err
	}
	if n, _ := result.RowsAffected(); n != 1 {
		return "", time.Time{}, ErrNotFound
	}
	return token, time.UnixMilli(expires.UnixMilli()), nil
}

// IssueAccess replaces the device's access token: one live access token per
// device.
func (s *Store) IssueAccess(ctx context.Context, deviceID int64) (string, time.Time, error) {
	token, hash, err := NewToken(AccessPrefix)
	if err != nil {
		return "", time.Time{}, err
	}
	expires := s.now().Add(AccessLifetime)
	result, err := s.db.ExecContext(ctx, `UPDATE devices SET access_hash = ?, access_expires_at = ? WHERE id = ?`, hash[:], expires.UnixMilli(), deviceID)
	if err != nil {
		return "", time.Time{}, err
	}
	if n, _ := result.RowsAffected(); n != 1 {
		return "", time.Time{}, ErrNotFound
	}
	return token, time.UnixMilli(expires.UnixMilli()), nil
}

// Refresh redeems a refresh token in one transaction:
//
//   - the current token of a device: verify (the device-key signature check)
//     runs first; then an approved user and device get a new access token and
//     a rotated refresh token, the old one kept as previous_refresh_hash. A
//     pending or rejected user or device gets ErrNotApproved and a revoked user
//     ErrRevoked, both leaving the token valid and unrotated.
//   - the previous token of a device: the device is revoked, its hashes
//     cleared and a refresh_reuse audit row written; ErrRefreshReuse.
//   - the last current or previous token of a device that is still revoked
//     (the tombstones): ErrRevoked, redeeming and changing nothing.
//   - anything else, or an expired token: ErrUnauthorized.
func (s *Store) Refresh(ctx context.Context, token string, verify func(Device) error) (Tokens, error) {
	hash := HashToken(token)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Tokens{}, err
	}
	defer tx.Rollback()
	now := s.now()
	device, err := scanDevice(tx.QueryRowContext(ctx, deviceColumns+` WHERE refresh_hash = ?`, hash[:]))
	if errors.Is(err, ErrNotFound) {
		return Tokens{}, s.detectReuse(ctx, tx, hash, now)
	}
	if err != nil {
		return Tokens{}, err
	}
	if !now.Before(device.RefreshExpiresAt) {
		return Tokens{}, ErrUnauthorized
	}
	if err := verify(device); err != nil {
		return Tokens{}, err
	}
	var userState string
	if err := tx.QueryRowContext(ctx, `SELECT state FROM users WHERE id = ?`, device.UserID).Scan(&userState); err != nil {
		return Tokens{}, err
	}
	switch {
	case UserState(userState) == UserRevoked || device.State == DeviceRevoked:
		return Tokens{}, ErrRevoked
	case UserState(userState) != UserApproved || device.State != DeviceApproved:
		return Tokens{}, ErrNotApproved
	}
	refresh, refreshHash, err := NewToken(RefreshPrefix)
	if err != nil {
		return Tokens{}, err
	}
	access, accessHash, err := NewToken(AccessPrefix)
	if err != nil {
		return Tokens{}, err
	}
	accessExpires, refreshExpires := now.Add(AccessLifetime).UnixMilli(), now.Add(RefreshLifetime).UnixMilli()
	if _, err := tx.ExecContext(ctx, `UPDATE devices SET previous_refresh_hash = refresh_hash, refresh_hash = ?, refresh_expires_at = ?,
		access_hash = ?, access_expires_at = ? WHERE id = ?`, refreshHash[:], refreshExpires, accessHash[:], accessExpires, device.ID); err != nil {
		return Tokens{}, err
	}
	if err := tx.Commit(); err != nil {
		return Tokens{}, err
	}
	return Tokens{UserID: device.UserID, DeviceID: device.ID, Access: access, AccessExpiresAt: time.UnixMilli(accessExpires),
		Refresh: refresh, RefreshExpiresAt: time.UnixMilli(refreshExpires)}, nil
}

func (s *Store) detectReuse(ctx context.Context, tx *sql.Tx, hash [32]byte, now time.Time) error {
	var id int64
	err := tx.QueryRowContext(ctx, `SELECT id FROM devices WHERE previous_refresh_hash = ?`, hash[:]).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return revokedLineage(ctx, tx, hash)
	}
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, revokeDevice, now.UnixMilli(), id); err != nil {
		return err
	}
	entry := AuditEntry{Actor: SystemActor, Action: "refresh_reuse", Target: DeviceTarget(id), Outcome: "revoked"}
	if err := insertAudit(ctx, tx, now.UnixMilli(), entry); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return ErrRefreshReuse
}

// revokedLineage answers ErrRevoked for a token recorded in a revoked
// device's refresh tombstones, and ErrUnauthorized otherwise (including after
// the device is approved again).
func revokedLineage(ctx context.Context, tx *sql.Tx, hash [32]byte) error {
	var n int
	err := tx.QueryRowContext(ctx, `SELECT count(*) FROM devices WHERE state = 'revoked'
		AND (revoked_refresh_hash = ? OR revoked_previous_refresh_hash = ?)`, hash[:], hash[:]).Scan(&n)
	switch {
	case err != nil:
		return err
	case n > 0:
		return ErrRevoked
	}
	return ErrUnauthorized
}
