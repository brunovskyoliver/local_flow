// Package accounts is flowd's remote account store: users, devices, token
// hashes and audit metadata in <data-dir>/flowd-remote.sqlite, the in-memory
// snapshot the listener authenticates from, and the server identity key. The
// schema is specs/014-remote-dictation-server/data-model.md. Nothing here holds
// content, tokens, claims or keys in the clear.
package accounts

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	_ "modernc.org/sqlite" // registers the "sqlite" driver
)

const (
	FileName         = "flowd-remote.sqlite"
	schemaVersion    = 2
	MaxPendingUsers  = 100
	MaxAuditRows     = 10000
	LastSeenInterval = time.Minute
	maxSubjectBytes  = 255
	maxDisplayBytes  = 320
	maxNameBytes     = 64
	publicKeyBytes   = 65
)

// UserState and DeviceState are the data-model states.
type UserState string
type DeviceState string

const (
	UserPending  UserState = "pending"
	UserApproved UserState = "approved"
	UserRejected UserState = "rejected"
	UserRevoked  UserState = "revoked"

	DevicePending  DeviceState = "pending"
	DeviceApproved DeviceState = "approved"
	DeviceRevoked  DeviceState = "revoked"
)

// Only flowd admin changes state; creation is the only other way in.
var userTransitions = map[UserState][]UserState{
	UserPending:  {UserApproved, UserRejected},
	UserApproved: {UserRevoked},
	UserRejected: {UserApproved},
	UserRevoked:  {UserApproved},
}

var deviceTransitions = map[DeviceState][]DeviceState{
	DevicePending:  {DeviceApproved, DeviceRevoked},
	DeviceApproved: {DeviceRevoked},
	DeviceRevoked:  {DeviceApproved},
}

var (
	ErrNotFound      = errors.New("accounts: not found")
	ErrPendingLimit  = errors.New("accounts: pending account limit reached")
	ErrDuplicateKey  = errors.New("accounts: device key already enrolled")
	ErrSchemaTooNew  = errors.New("accounts: database schema is newer than this flowd")
	ErrInvalidRecord = errors.New("accounts: invalid record")
)

// TransitionError refuses a state change the data model does not allow.
type TransitionError struct {
	Kind     string // "user" or "device"
	From, To string
}

func (e *TransitionError) Error() string {
	return fmt.Sprintf("accounts: %s cannot go from %s to %s", e.Kind, e.From, e.To)
}

// User is one row of users. Display is shown only by flowd admin.
type User struct {
	ID        int64
	Provider  string
	Subject   string
	Display   string
	State     UserState
	CreatedAt time.Time
	ChangedAt time.Time
}

// Device is one row of devices. The hashes are SHA-256 of tokens, never
// tokens. LastSeenAt is zero until the device is first seen.
type Device struct {
	ID                  int64
	UserID              int64
	Name                string
	PublicKey           []byte
	State               DeviceState
	RefreshHash         []byte
	PreviousRefreshHash []byte
	RefreshExpiresAt    time.Time
	AccessHash          []byte
	AccessExpiresAt     time.Time
	EnrolledAt          time.Time
	LastSeenAt          time.Time
	ChangedAt           time.Time
}

// Store is the SQLite account store. It is safe for concurrent use; flowd
// serve and flowd admin may hold it open at once from separate processes.
type Store struct {
	db   *sql.DB
	path string
	now  func() time.Time
}

const schema = `
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  provider TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  subject TEXT NOT NULL CHECK (length(CAST(subject AS BLOB)) BETWEEN 1 AND 255),
  display TEXT CHECK (display IS NULL OR length(CAST(display AS BLOB)) <= 320),
  state TEXT NOT NULL CHECK (state IN ('pending', 'approved', 'rejected', 'revoked')),
  created_at INTEGER NOT NULL,
  changed_at INTEGER NOT NULL,
  UNIQUE (provider, subject)
);
CREATE TABLE devices (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  name TEXT NOT NULL CHECK (length(CAST(name AS BLOB)) BETWEEN 1 AND 64),
  public_key BLOB NOT NULL UNIQUE CHECK (length(public_key) = 65 AND substr(public_key, 1, 1) = x'04'),
  state TEXT NOT NULL CHECK (state IN ('pending', 'approved', 'revoked')),
  refresh_hash BLOB CHECK (refresh_hash IS NULL OR length(refresh_hash) = 32),
  previous_refresh_hash BLOB CHECK (previous_refresh_hash IS NULL OR length(previous_refresh_hash) = 32),
  refresh_expires_at INTEGER,
  access_hash BLOB CHECK (access_hash IS NULL OR length(access_hash) = 32),
  access_expires_at INTEGER,
  enrolled_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  changed_at INTEGER NOT NULL
);
CREATE INDEX devices_user ON devices(user_id);
CREATE UNIQUE INDEX devices_refresh ON devices(refresh_hash) WHERE refresh_hash IS NOT NULL;
CREATE INDEX devices_previous_refresh ON devices(previous_refresh_hash) WHERE previous_refresh_hash IS NOT NULL;
CREATE TABLE audit (
  id INTEGER PRIMARY KEY,
  at INTEGER NOT NULL,
  actor TEXT NOT NULL CHECK (
    actor = 'system'
    OR (actor GLOB 'admin:?*' AND length(actor) <= 70)
    OR (actor GLOB 'user:[0-9]*' AND substr(actor, 6) NOT GLOB '*[^0-9]*')
    OR (actor GLOB 'device:[0-9]*' AND substr(actor, 8) NOT GLOB '*[^0-9]*')),
  action TEXT NOT NULL CHECK (action IN ('sign_in', 'enroll', 'approve', 'reject', 'revoke', 'refresh',
    'refresh_reuse', 'cross_user_attempt', 'rate_limited', 'pin_rejected')),
  target TEXT CHECK (target IS NULL
    OR (target GLOB 'user:[0-9]*' AND substr(target, 6) NOT GLOB '*[^0-9]*')
    OR (target GLOB 'device:[0-9]*' AND substr(target, 8) NOT GLOB '*[^0-9]*')),
  outcome TEXT NOT NULL CHECK (outcome IN ('ok', 'unauthorized', 'token_expired', 'not_approved', 'revoked',
    'busy', 'invalid_message', 'unsupported_version', 'limit_exceeded', 'worker_unavailable', 'internal'))
);
PRAGMA user_version = 1;
`

// schemaV2 adds the revocation tombstones: revocation clears the token
// hashes but keeps them here, so the device's last access token (at hello)
// and last refresh tokens (at refresh) are answered revoked instead of
// unauthorized. A tombstone never redeems anything.
const schemaV2 = `
ALTER TABLE devices ADD COLUMN revoked_access_hash BLOB
  CHECK (revoked_access_hash IS NULL OR length(revoked_access_hash) = 32);
ALTER TABLE devices ADD COLUMN revoked_refresh_hash BLOB
  CHECK (revoked_refresh_hash IS NULL OR length(revoked_refresh_hash) = 32);
ALTER TABLE devices ADD COLUMN revoked_previous_refresh_hash BLOB
  CHECK (revoked_previous_refresh_hash IS NULL OR length(revoked_previous_refresh_hash) = 32);
CREATE INDEX devices_revoked_refresh ON devices(revoked_refresh_hash) WHERE revoked_refresh_hash IS NOT NULL;
CREATE INDEX devices_revoked_previous_refresh ON devices(revoked_previous_refresh_hash) WHERE revoked_previous_refresh_hash IS NOT NULL;
PRAGMA user_version = 2;
`

// migrations[v] brings a version v database to v+1.
var migrations = []string{schema, schemaV2}

// revokeDevice is the device revocation update (admin revoke and refresh
// reuse): the token hashes are cleared and move to the tombstones (a hash
// already cleared keeps its earlier tombstone). Parameters: changed_at, id.
const revokeDevice = `UPDATE devices SET state = 'revoked', changed_at = ?,
  revoked_access_hash = coalesce(access_hash, revoked_access_hash),
  revoked_refresh_hash = coalesce(refresh_hash, revoked_refresh_hash),
  revoked_previous_refresh_hash = coalesce(previous_refresh_hash, revoked_previous_refresh_hash),
  refresh_hash = NULL, previous_refresh_hash = NULL, access_hash = NULL WHERE id = ?`

// Open opens (creating when missing) the store in dir. A missing dir is
// created 0700 and a new database file 0600. now is the server clock.
func Open(dir string, now func() time.Time) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("accounts: create data directory: %w", err)
	}
	path := filepath.Join(dir, FileName)
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("accounts: create database: %w", err)
	}
	_ = file.Close()
	if err := os.Chmod(path, 0o600); err != nil {
		return nil, err
	}
	query := url.Values{}
	query.Add("_pragma", "busy_timeout(5000)")
	query.Add("_pragma", "foreign_keys(1)")
	query.Add("_pragma", "journal_mode(WAL)")
	query.Add("_pragma", "synchronous(NORMAL)")
	query.Set("_txlock", "immediate")
	db, err := sql.Open("sqlite", "file:"+path+"?"+query.Encode())
	if err != nil {
		return nil, err
	}
	s := &Store{db: db, path: path, now: now}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate() error {
	var version int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return fmt.Errorf("accounts: read schema version: %w", err)
	}
	switch {
	case version == schemaVersion:
		return nil
	case version > schemaVersion:
		return ErrSchemaTooNew
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for v := version; v < schemaVersion; v++ {
		if _, err := tx.Exec(migrations[v]); err != nil {
			return fmt.Errorf("accounts: migrate schema to version %d: %w", v+1, err)
		}
	}
	return tx.Commit()
}

// Close closes the database.
func (s *Store) Close() error { return s.db.Close() }

// Path is the database file.
func (s *Store) Path() string { return s.path }

func (s *Store) millis() int64 { return s.now().UnixMilli() }

func fromMillis(ms sql.NullInt64) time.Time {
	if !ms.Valid || ms.Int64 == 0 {
		return time.Time{}
	}
	return time.UnixMilli(ms.Int64)
}

func hasControl(s string) bool {
	return strings.IndexFunc(s, unicode.IsControl) >= 0 || !utf8.ValidString(s)
}

// EnsureUser returns the user for (provider, subject), creating a pending one
// when the identity is new. Sign-in never changes a known user's state. A new
// identity while 100 users are pending is ErrPendingLimit.
func (s *Store) EnsureUser(ctx context.Context, provider, subject, display string) (User, bool, error) {
	if (provider != "apple" && provider != "google") || len(subject) == 0 || len(subject) > maxSubjectBytes ||
		len(display) > maxDisplayBytes || hasControl(subject) || hasControl(display) {
		return User{}, false, ErrInvalidRecord
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return User{}, false, err
	}
	defer tx.Rollback()
	user, err := scanUser(tx.QueryRowContext(ctx, userColumns+` WHERE provider = ? AND subject = ?`, provider, subject))
	if err == nil {
		return user, false, tx.Commit()
	}
	if !errors.Is(err, ErrNotFound) {
		return User{}, false, err
	}
	var pending int
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM users WHERE state = 'pending'`).Scan(&pending); err != nil {
		return User{}, false, err
	}
	if pending >= MaxPendingUsers {
		return User{}, false, ErrPendingLimit
	}
	now := s.millis()
	var displayValue any
	if display != "" {
		displayValue = display
	}
	result, err := tx.ExecContext(ctx, `INSERT INTO users (provider, subject, display, state, created_at, changed_at) VALUES (?, ?, ?, 'pending', ?, ?)`,
		provider, subject, displayValue, now, now)
	if err != nil {
		return User{}, false, err
	}
	id, _ := result.LastInsertId()
	if err := tx.Commit(); err != nil {
		return User{}, false, err
	}
	return User{ID: id, Provider: provider, Subject: subject, Display: display, State: UserPending,
		CreatedAt: time.UnixMilli(now), ChangedAt: time.UnixMilli(now)}, true, nil
}

// AddDevice enrolls a pending device for userID. name must already have its
// control characters removed (1…64 bytes); publicKey is X9.63 uncompressed.
func (s *Store) AddDevice(ctx context.Context, userID int64, name string, publicKey []byte) (Device, error) {
	if len(name) == 0 || len(name) > maxNameBytes || hasControl(name) || len(publicKey) != publicKeyBytes || publicKey[0] != 0x04 {
		return Device{}, ErrInvalidRecord
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Device{}, err
	}
	defer tx.Rollback()
	var exists int
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM devices WHERE public_key = ?`, publicKey).Scan(&exists); err != nil {
		return Device{}, err
	}
	if exists > 0 {
		return Device{}, ErrDuplicateKey
	}
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM users WHERE id = ?`, userID).Scan(&exists); err != nil {
		return Device{}, err
	}
	if exists == 0 {
		return Device{}, ErrNotFound
	}
	now := s.millis()
	result, err := tx.ExecContext(ctx, `INSERT INTO devices (user_id, name, public_key, state, enrolled_at, last_seen_at, changed_at) VALUES (?, ?, ?, 'pending', ?, 0, ?)`,
		userID, name, publicKey, now, now)
	if err != nil {
		return Device{}, err
	}
	id, _ := result.LastInsertId()
	if err := tx.Commit(); err != nil {
		return Device{}, err
	}
	return s.Device(ctx, id)
}

const userColumns = `SELECT id, provider, subject, coalesce(display, ''), state, created_at, changed_at FROM users`

type rowScanner interface{ Scan(...any) error }

func scanUser(row rowScanner) (User, error) {
	var u User
	var state string
	var created, changed int64
	if err := row.Scan(&u.ID, &u.Provider, &u.Subject, &u.Display, &state, &created, &changed); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return User{}, ErrNotFound
		}
		return User{}, err
	}
	u.State, u.CreatedAt, u.ChangedAt = UserState(state), time.UnixMilli(created), time.UnixMilli(changed)
	return u, nil
}

const deviceColumns = `SELECT id, user_id, name, public_key, state, refresh_hash, previous_refresh_hash, refresh_expires_at,
  access_hash, access_expires_at, enrolled_at, last_seen_at, changed_at FROM devices`

func scanDevice(row rowScanner) (Device, error) {
	var d Device
	var state string
	var refreshExpires, accessExpires, enrolled, lastSeen, changed sql.NullInt64
	if err := row.Scan(&d.ID, &d.UserID, &d.Name, &d.PublicKey, &state, &d.RefreshHash, &d.PreviousRefreshHash, &refreshExpires,
		&d.AccessHash, &accessExpires, &enrolled, &lastSeen, &changed); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Device{}, ErrNotFound
		}
		return Device{}, err
	}
	d.State = DeviceState(state)
	d.RefreshExpiresAt, d.AccessExpiresAt = fromMillis(refreshExpires), fromMillis(accessExpires)
	d.EnrolledAt, d.LastSeenAt, d.ChangedAt = fromMillis(enrolled), fromMillis(lastSeen), fromMillis(changed)
	return d, nil
}

// User returns one user or ErrNotFound.
func (s *Store) User(ctx context.Context, id int64) (User, error) {
	return scanUser(s.db.QueryRowContext(ctx, userColumns+` WHERE id = ?`, id))
}

// Users returns every user by id.
func (s *Store) Users(ctx context.Context) ([]User, error) {
	rows, err := s.db.QueryContext(ctx, userColumns+` ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var users []User
	for rows.Next() {
		user, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		users = append(users, user)
	}
	return users, rows.Err()
}

// Device returns one device or ErrNotFound.
func (s *Store) Device(ctx context.Context, id int64) (Device, error) {
	return scanDevice(s.db.QueryRowContext(ctx, deviceColumns+` WHERE id = ?`, id))
}

// DeviceByKey returns the device enrolled with publicKey or ErrNotFound.
func (s *Store) DeviceByKey(ctx context.Context, publicKey []byte) (Device, error) {
	return scanDevice(s.db.QueryRowContext(ctx, deviceColumns+` WHERE public_key = ?`, publicKey))
}

// Devices returns the devices of userID by id, or every device when userID is 0.
func (s *Store) Devices(ctx context.Context, userID int64) ([]Device, error) {
	query, args := deviceColumns+` ORDER BY id`, []any{}
	if userID != 0 {
		query, args = deviceColumns+` WHERE user_id = ? ORDER BY id`, []any{userID}
	}
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var devices []Device
	for rows.Next() {
		device, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		devices = append(devices, device)
	}
	return devices, rows.Err()
}

func allowed[T comparable](table map[T][]T, from, to T) bool {
	for _, next := range table[from] {
		if next == to {
			return true
		}
	}
	return false
}

var stateActions = map[string]string{"approved": "approve", "rejected": "reject", "revoked": "revoke"}

// SetUserState applies an admin transition and audits it in one transaction.
// Device rows are left as they are.
func (s *Store) SetUserState(ctx context.Context, id int64, to UserState, actor string) error {
	return s.transition(ctx, "user", id, string(to), actor, func(from string) bool {
		return allowed(userTransitions, UserState(from), to)
	})
}

// SetDeviceState applies an admin transition and audits it in one
// transaction. Revocation clears the refresh, previous refresh and access
// hashes; the access hash is kept only as revoked_access_hash so the token is
// recognized as revoked.
func (s *Store) SetDeviceState(ctx context.Context, id int64, to DeviceState, actor string) error {
	return s.transition(ctx, "device", id, string(to), actor, func(from string) bool {
		return allowed(deviceTransitions, DeviceState(from), to)
	})
}

func (s *Store) transition(ctx context.Context, kind string, id int64, to, actor string, ok func(from string) bool) error {
	if !validActor(actor) {
		return ErrInvalidRecord
	}
	table := kind + "s"
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var from string
	if err := tx.QueryRowContext(ctx, `SELECT state FROM `+table+` WHERE id = ?`, id).Scan(&from); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if !ok(from) {
		return &TransitionError{Kind: kind, From: from, To: to}
	}
	now := s.millis()
	update, args := `UPDATE `+table+` SET state = ?, changed_at = ? WHERE id = ?`, []any{to, now, id}
	if kind == "device" && to == string(DeviceRevoked) {
		update, args = revokeDevice, []any{now, id}
	}
	if _, err := tx.ExecContext(ctx, update, args...); err != nil {
		return err
	}
	entry := AuditEntry{Actor: actor, Action: stateActions[to], Target: kind + ":" + strconv.FormatInt(id, 10), Outcome: "ok"}
	if err := insertAudit(ctx, tx, now, entry); err != nil {
		return err
	}
	return tx.Commit()
}

// TouchDevice records that the device was seen, at most once a minute. It
// reports whether it wrote.
func (s *Store) TouchDevice(ctx context.Context, id int64) (bool, error) {
	now := s.millis()
	result, err := s.db.ExecContext(ctx, `UPDATE devices SET last_seen_at = ? WHERE id = ? AND last_seen_at <= ?`,
		now, id, now-LastSeenInterval.Milliseconds())
	if err != nil {
		return false, err
	}
	n, _ := result.RowsAffected()
	return n == 1, nil
}

// AuditEntry is one audit row: identifiers, times and outcomes only.
type AuditEntry struct {
	ID      int64
	At      time.Time
	Actor   string // admin:<unix user>, user:<id>, device:<id> or system
	Action  string
	Target  string // user:<id>, device:<id> or empty
	Outcome string // ok or a channel error code
}

// SystemActor is the audit actor for flowd itself.
const SystemActor = "system"

func AdminActor(unixUser string) string { return "admin:" + unixUser }
func UserActor(id int64) string         { return "user:" + strconv.FormatInt(id, 10) }
func DeviceActor(id int64) string       { return "device:" + strconv.FormatInt(id, 10) }
func UserTarget(id int64) string        { return UserActor(id) }
func DeviceTarget(id int64) string      { return DeviceActor(id) }

var (
	adminPattern = regexp.MustCompile(`^admin:[A-Za-z0-9._-]{1,64}$`)
	idPattern    = regexp.MustCompile(`^(user|device):[0-9]{1,19}$`)
	auditActions = map[string]bool{
		"sign_in": true, "enroll": true, "approve": true, "reject": true, "revoke": true, "refresh": true,
		"refresh_reuse": true, "cross_user_attempt": true, "rate_limited": true, "pin_rejected": true,
	}
	auditOutcomes = map[string]bool{
		"ok": true, "unauthorized": true, "token_expired": true, "not_approved": true, "revoked": true, "busy": true,
		"invalid_message": true, "unsupported_version": true, "limit_exceeded": true, "worker_unavailable": true, "internal": true,
	}
)

func validActor(actor string) bool {
	return actor == SystemActor || adminPattern.MatchString(actor) || idPattern.MatchString(actor)
}

// Audit appends one row, pruning the oldest past MaxAuditRows in the same
// transaction.
func (s *Store) Audit(ctx context.Context, entry AuditEntry) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := insertAudit(ctx, tx, s.millis(), entry); err != nil {
		return err
	}
	return tx.Commit()
}

func insertAudit(ctx context.Context, tx *sql.Tx, at int64, entry AuditEntry) error {
	if !validActor(entry.Actor) || !auditActions[entry.Action] || !auditOutcomes[entry.Outcome] ||
		(entry.Target != "" && !idPattern.MatchString(entry.Target)) {
		return ErrInvalidRecord
	}
	var target any
	if entry.Target != "" {
		target = entry.Target
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO audit (at, actor, action, target, outcome) VALUES (?, ?, ?, ?, ?)`,
		at, entry.Actor, entry.Action, target, entry.Outcome); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `DELETE FROM audit WHERE id <= (SELECT id FROM audit ORDER BY id DESC LIMIT 1 OFFSET ?)`, MaxAuditRows)
	return err
}

// AuditLog returns up to limit rows, newest first.
func (s *Store) AuditLog(ctx context.Context, limit int) ([]AuditEntry, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, at, actor, action, coalesce(target, ''), outcome FROM audit ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var entries []AuditEntry
	for rows.Next() {
		var e AuditEntry
		var at int64
		if err := rows.Scan(&e.ID, &at, &e.Actor, &e.Action, &e.Target, &e.Outcome); err != nil {
			return nil, err
		}
		e.At = time.UnixMilli(at)
		entries = append(entries, e)
	}
	return entries, rows.Err()
}
