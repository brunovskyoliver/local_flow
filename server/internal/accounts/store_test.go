package accounts

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// fakeClock is a settable server clock.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func newClock() *fakeClock { return &fakeClock{now: time.UnixMilli(1_790_000_000_000)} }

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

func openStore(t *testing.T) (*Store, *fakeClock, string) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "data")
	clock := newClock()
	store, err := Open(dir, clock.Now)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	return store, clock, dir
}

// deviceKey returns a distinct 65-byte X9.63-shaped key. The store checks the
// shape; the protocol layer checks the curve.
func deviceKey(n byte) []byte {
	key := bytes.Repeat([]byte{n}, 65)
	key[0] = 0x04
	return key
}

var ctx = context.Background()

func TestOpenCreatesPrivateWALDatabase(t *testing.T) {
	store, _, dir := openStore(t)
	info, err := os.Stat(dir)
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode %v %v", info.Mode(), err)
	}
	info, err = os.Stat(filepath.Join(dir, FileName))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("file mode %v %v", info.Mode(), err)
	}
	var mode string
	var version int
	if err := store.db.QueryRow("PRAGMA journal_mode").Scan(&mode); err != nil || mode != "wal" {
		t.Fatal(mode, err)
	}
	if err := store.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 2 {
		t.Fatal(version, err)
	}
	// Reopening an initialized file keeps it; a newer schema is refused.
	store.Close()
	again, err := Open(dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := again.db.Exec("PRAGMA user_version = 3"); err != nil {
		t.Fatal(err)
	}
	again.Close()
	if _, err := Open(dir, time.Now); !errors.Is(err, ErrSchemaTooNew) {
		t.Fatal(err)
	}
}

func TestEnsureUser(t *testing.T) {
	store, _, _ := openStore(t)
	user, created, err := store.EnsureUser(ctx, "apple", "sub-1", "oliver@example.com")
	if err != nil || !created || user.State != UserPending || user.ID == 0 {
		t.Fatal(user, created, err)
	}
	again, created, err := store.EnsureUser(ctx, "apple", "sub-1", "other@example.com")
	if err != nil || created || again.ID != user.ID {
		t.Fatal(again, created, err)
	}
	google, created, err := store.EnsureUser(ctx, "google", "sub-1", "")
	if err != nil || !created || google.ID == user.ID || google.Display != "" {
		t.Fatal(google, err)
	}
	for name, args := range map[string][3]string{
		"provider":        {"github", "s", ""},
		"empty subject":   {"apple", "", ""},
		"subject 256":     {"apple", string(bytes.Repeat([]byte("s"), 256)), ""},
		"display 321":     {"apple", "s2", string(bytes.Repeat([]byte("d"), 321))},
		"control subject": {"apple", "s\x00", ""},
	} {
		if _, _, err := store.EnsureUser(ctx, args[0], args[1], args[2]); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	if _, _, err := store.EnsureUser(ctx, "apple", string(bytes.Repeat([]byte("s"), 255)), string(bytes.Repeat([]byte("d"), 320))); err != nil {
		t.Fatal("255-byte subject and 320-byte display must fit", err)
	}
}

// Sign-in never changes a known user's state, whatever it is.
func TestEnsureUserKeepsState(t *testing.T) {
	store, _, _ := openStore(t)
	user, _, _ := store.EnsureUser(ctx, "apple", "sub", "")
	if err := store.SetUserState(ctx, user.ID, UserRejected, AdminActor("oliver")); err != nil {
		t.Fatal(err)
	}
	again, created, err := store.EnsureUser(ctx, "apple", "sub", "")
	if err != nil || created || again.State != UserRejected {
		t.Fatal(again, err)
	}
}

func TestPendingUserCap(t *testing.T) {
	store, _, _ := openStore(t)
	for i := range MaxPendingUsers {
		if _, _, err := store.EnsureUser(ctx, "google", fmt.Sprint("sub-", i), ""); err != nil {
			t.Fatal(i, err)
		}
	}
	if _, _, err := store.EnsureUser(ctx, "google", "one-too-many", ""); !errors.Is(err, ErrPendingLimit) {
		t.Fatal(err)
	}
	// Known identities still sign in; approving one frees a slot.
	if _, created, err := store.EnsureUser(ctx, "google", "sub-3", ""); err != nil || created {
		t.Fatal(err)
	}
	if err := store.SetUserState(ctx, 1, UserApproved, AdminActor("oliver")); err != nil {
		t.Fatal(err)
	}
	if _, created, err := store.EnsureUser(ctx, "google", "one-too-many", ""); err != nil || !created {
		t.Fatal(err)
	}
}

func TestDevices(t *testing.T) {
	store, clock, _ := openStore(t)
	user, _, _ := store.EnsureUser(ctx, "apple", "sub", "")
	device, err := store.AddDevice(ctx, user.ID, "MacBook Pro", deviceKey(1))
	if err != nil || device.State != DevicePending || device.UserID != user.ID || !device.LastSeenAt.IsZero() || !device.EnrolledAt.Equal(clock.Now()) {
		t.Fatal(device, err)
	}
	if _, err := store.AddDevice(ctx, user.ID, "Other", deviceKey(1)); !errors.Is(err, ErrDuplicateKey) {
		t.Fatal("duplicate public key", err)
	}
	for name, tc := range map[string]struct {
		user int64
		name string
		key  []byte
	}{
		"unknown user":   {999, "Mac", deviceKey(2)},
		"empty name":     {user.ID, "", deviceKey(2)},
		"name 65 bytes":  {user.ID, string(bytes.Repeat([]byte("n"), 65)), deviceKey(2)},
		"control name":   {user.ID, "Mac\x1b", deviceKey(2)},
		"key 64 bytes":   {user.ID, "Mac", deviceKey(2)[:64]},
		"key compressed": {user.ID, "Mac", append([]byte{0x02}, deviceKey(2)[1:]...)},
	} {
		if _, err := store.AddDevice(ctx, tc.user, tc.name, tc.key); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	second, err := store.AddDevice(ctx, user.ID, string(bytes.Repeat([]byte("n"), 64)), deviceKey(3))
	if err != nil {
		t.Fatal(err)
	}
	devices, err := store.Devices(ctx, user.ID)
	if err != nil || len(devices) != 2 || devices[1].ID != second.ID {
		t.Fatal(devices, err)
	}
	if _, err := store.Device(ctx, 999); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
}

// The database refuses rows that break its CHECK constraints even when Go
// validation is bypassed.
func TestSchemaConstraints(t *testing.T) {
	store, _, _ := openStore(t)
	user, _, _ := store.EnsureUser(ctx, "apple", "sub", "")
	for name, statement := range map[string]string{
		"provider":     `INSERT INTO users (provider, subject, state, created_at, changed_at) VALUES ('github', 'x', 'pending', 0, 0)`,
		"user state":   `INSERT INTO users (provider, subject, state, created_at, changed_at) VALUES ('apple', 'x', 'banned', 0, 0)`,
		"subject 256":  `INSERT INTO users (provider, subject, state, created_at, changed_at) VALUES ('apple', printf('%.256c', 's'), 'pending', 0, 0)`,
		"duplicate":    `INSERT INTO users (provider, subject, state, created_at, changed_at) VALUES ('apple', 'sub', 'pending', 0, 0)`,
		"device state": fmt.Sprintf(`INSERT INTO devices (user_id, name, public_key, state, enrolled_at, last_seen_at, changed_at) VALUES (%d, 'n', x'04%0128x', 'rejected', 0, 0, 0)`, user.ID, 0),
		"key length":   fmt.Sprintf(`INSERT INTO devices (user_id, name, public_key, state, enrolled_at, last_seen_at, changed_at) VALUES (%d, 'n', x'0401', 'pending', 0, 0, 0)`, user.ID),
		"hash length":  fmt.Sprintf(`INSERT INTO devices (user_id, name, public_key, state, access_hash, enrolled_at, last_seen_at, changed_at) VALUES (%d, 'n', x'04%0128x', 'pending', x'01', 0, 0, 0)`, user.ID, 0),
		"foreign key":  `INSERT INTO devices (user_id, name, public_key, state, enrolled_at, last_seen_at, changed_at) VALUES (999, 'n', x'04` + fmt.Sprintf("%0128x", 1) + `', 'pending', 0, 0, 0)`,
		"audit action": `INSERT INTO audit (at, actor, action, outcome) VALUES (0, 'system', 'delete_everything', 'ok')`,
		"audit actor":  `INSERT INTO audit (at, actor, action, outcome) VALUES (0, 'root', 'approve', 'ok')`,
		"audit result": `INSERT INTO audit (at, actor, action, outcome) VALUES (0, 'system', 'approve', 'fine')`,
	} {
		if _, err := store.db.Exec(statement); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}

var wantUserTransitions = map[UserState][]UserState{
	UserPending:  {UserApproved, UserRejected},
	UserApproved: {UserRevoked},
	UserRejected: {UserApproved},
	UserRevoked:  {UserApproved},
}

var wantDeviceTransitions = map[DeviceState][]DeviceState{
	DevicePending:  {DeviceApproved, DeviceRevoked},
	DeviceApproved: {DeviceRevoked},
	DeviceRevoked:  {DeviceApproved},
}

func contains[T comparable](list []T, v T) bool {
	for _, item := range list {
		if item == v {
			return true
		}
	}
	return false
}

// Every pair of states is tried: the data-model transitions succeed and write
// an audit row, every other one is a *TransitionError and changes nothing.
func TestUserTransitions(t *testing.T) {
	states := []UserState{UserPending, UserApproved, UserRejected, UserRevoked}
	for _, from := range states {
		for _, to := range states {
			store, clock, _ := openStore(t)
			user, _, _ := store.EnsureUser(ctx, "apple", "sub", "")
			if from != UserPending {
				forceUserState(t, store, user.ID, from)
			}
			clock.Advance(time.Second)
			err := store.SetUserState(ctx, user.ID, to, AdminActor("oliver"))
			got, _ := store.User(ctx, user.ID)
			if contains(wantUserTransitions[from], to) {
				if err != nil || got.State != to || !got.ChangedAt.Equal(clock.Now()) {
					t.Errorf("%s -> %s: %v %v", from, to, got.State, err)
				}
				entries, _ := store.AuditLog(ctx, 1)
				if len(entries) != 1 || entries[0].Actor != "admin:oliver" || entries[0].Target != fmt.Sprint("user:", user.ID) || entries[0].Outcome != "ok" {
					t.Errorf("%s -> %s audit %+v", from, to, entries)
				}
			} else {
				var transition *TransitionError
				if !errors.As(err, &transition) || got.State != from {
					t.Errorf("%s -> %s allowed: %v", from, to, err)
				}
			}
		}
	}
	store, _, _ := openStore(t)
	if err := store.SetUserState(ctx, 42, UserApproved, AdminActor("oliver")); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
}

func forceUserState(t *testing.T, store *Store, id int64, state UserState) {
	t.Helper()
	if _, err := store.db.Exec(`UPDATE users SET state = ? WHERE id = ?`, string(state), id); err != nil {
		t.Fatal(err)
	}
}

func setHashes(t *testing.T, store *Store, id int64) {
	t.Helper()
	hash := bytes.Repeat([]byte{7}, 32)
	if _, err := store.db.Exec(`UPDATE devices SET refresh_hash = ?, previous_refresh_hash = ?, access_hash = ? WHERE id = ?`, hash, hash, hash, id); err != nil {
		t.Fatal(err)
	}
}

func TestDeviceTransitions(t *testing.T) {
	states := []DeviceState{DevicePending, DeviceApproved, DeviceRevoked}
	for _, from := range states {
		for _, to := range states {
			store, _, _ := openStore(t)
			user, _, _ := store.EnsureUser(ctx, "apple", "sub", "")
			device, _ := store.AddDevice(ctx, user.ID, "Mac", deviceKey(1))
			if _, err := store.db.Exec(`UPDATE devices SET state = ? WHERE id = ?`, string(from), device.ID); err != nil {
				t.Fatal(err)
			}
			setHashes(t, store, device.ID)
			err := store.SetDeviceState(ctx, device.ID, to, AdminActor("oliver"))
			got, _ := store.Device(ctx, device.ID)
			if !contains(wantDeviceTransitions[from], to) {
				var transition *TransitionError
				if !errors.As(err, &transition) || got.State != from {
					t.Errorf("%s -> %s allowed: %v", from, to, err)
				}
				continue
			}
			if err != nil || got.State != to {
				t.Errorf("%s -> %s: %v", from, to, err)
			}
			cleared := got.RefreshHash == nil && got.PreviousRefreshHash == nil && got.AccessHash == nil
			if to == DeviceRevoked && !cleared {
				t.Errorf("revocation must clear the three hashes: %+v", got)
			}
			if to != DeviceRevoked && cleared {
				t.Errorf("%s -> %s cleared hashes", from, to)
			}
		}
	}
}

// Revoking a user leaves the device rows as they are.
func TestRevokeUserLeavesDevices(t *testing.T) {
	store, _, _ := openStore(t)
	user, _, _ := store.EnsureUser(ctx, "apple", "sub", "")
	device, _ := store.AddDevice(ctx, user.ID, "Mac", deviceKey(1))
	_ = store.SetUserState(ctx, user.ID, UserApproved, AdminActor("oliver"))
	_ = store.SetDeviceState(ctx, device.ID, DeviceApproved, AdminActor("oliver"))
	setHashes(t, store, device.ID)
	if err := store.SetUserState(ctx, user.ID, UserRevoked, AdminActor("oliver")); err != nil {
		t.Fatal(err)
	}
	got, _ := store.Device(ctx, device.ID)
	if got.State != DeviceApproved || got.AccessHash == nil {
		t.Fatalf("%+v", got)
	}
}

func TestTouchDeviceAtMostOncePerMinute(t *testing.T) {
	store, clock, _ := openStore(t)
	user, _, _ := store.EnsureUser(ctx, "apple", "sub", "")
	device, _ := store.AddDevice(ctx, user.ID, "Mac", deviceKey(1))
	first := clock.Now()
	for i, tc := range []struct {
		advance time.Duration
		written bool
		seen    time.Time
	}{
		{0, true, first},
		{30 * time.Second, false, first},
		{29 * time.Second, false, first},
		{time.Second, true, first.Add(time.Minute)},
	} {
		clock.Advance(tc.advance)
		written, err := store.TouchDevice(ctx, device.ID)
		got, _ := store.Device(ctx, device.ID)
		if err != nil || written != tc.written || !got.LastSeenAt.Equal(tc.seen) {
			t.Fatalf("step %d: written %v seen %v %v", i, written, got.LastSeenAt, err)
		}
	}
}

func TestAuditValidation(t *testing.T) {
	store, clock, _ := openStore(t)
	valid := []AuditEntry{
		{Actor: AdminActor("oliver"), Action: "approve", Target: "user:1", Outcome: "ok"},
		{Actor: UserActor(3), Action: "sign_in", Outcome: "busy"},
		{Actor: DeviceActor(5), Action: "refresh_reuse", Target: DeviceTarget(5), Outcome: "revoked"},
		{Actor: SystemActor, Action: "cross_user_attempt", Target: UserTarget(2), Outcome: "invalid_message"},
	}
	for _, entry := range valid {
		if err := store.Audit(ctx, entry); err != nil {
			t.Errorf("%+v: %v", entry, err)
		}
	}
	for _, entry := range []AuditEntry{
		{Actor: "root", Action: "approve", Outcome: "ok"},
		{Actor: "admin:", Action: "approve", Outcome: "ok"},
		{Actor: "user:x", Action: "approve", Outcome: "ok"},
		{Actor: SystemActor, Action: "export", Outcome: "ok"},
		{Actor: SystemActor, Action: "approve", Target: "group:1", Outcome: "ok"},
		{Actor: SystemActor, Action: "approve", Outcome: "oliver@example.com"},
	} {
		if err := store.Audit(ctx, entry); err == nil {
			t.Errorf("%+v accepted", entry)
		}
	}
	entries, err := store.AuditLog(ctx, 50)
	if err != nil || len(entries) != len(valid) || entries[0].Action != "cross_user_attempt" || !entries[0].At.Equal(clock.Now()) {
		t.Fatalf("newest first: %+v %v", entries, err)
	}
}

// At most 10,000 audit rows: the insert that exceeds the cap deletes the
// oldest in the same transaction.
func TestAuditCap(t *testing.T) {
	store, _, _ := openStore(t)
	tx, err := store.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	for i := range MaxAuditRows {
		if _, err := tx.Exec(`INSERT INTO audit (at, actor, action, target, outcome) VALUES (?, 'system', 'refresh', ?, 'ok')`, i, fmt.Sprint("device:", i)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := store.Audit(ctx, AuditEntry{Actor: SystemActor, Action: "enroll", Target: "device:x1", Outcome: "ok"}); err == nil {
		t.Fatal("target must be user:<id> or device:<id>")
	}
	if err := store.Audit(ctx, AuditEntry{Actor: SystemActor, Action: "enroll", Target: "device:10001", Outcome: "ok"}); err != nil {
		t.Fatal(err)
	}
	var count int
	var oldest string
	_ = store.db.QueryRow(`SELECT count(*) FROM audit`).Scan(&count)
	_ = store.db.QueryRow(`SELECT target FROM audit ORDER BY id LIMIT 1`).Scan(&oldest)
	if count != MaxAuditRows || oldest != "device:1" {
		t.Fatalf("count %d oldest %s", count, oldest)
	}
}

func TestDeviceByKey(t *testing.T) {
	store, _, _ := openStore(t)
	user, _, _ := store.EnsureUser(ctx, "apple", "sub", "")
	device, _ := store.AddDevice(ctx, user.ID, "Mac", deviceKey(1))
	got, err := store.DeviceByKey(ctx, deviceKey(1))
	if err != nil || got.ID != device.ID || got.UserID != user.ID {
		t.Fatal(got, err)
	}
	if _, err := store.DeviceByKey(ctx, deviceKey(2)); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
}

// A version 1 file (before the revoked access token tombstone) is migrated to
// version 2 in place, keeping its rows.
func TestMigrateFromVersion1(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "data")
	store, err := Open(dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	user, _, _ := store.EnsureUser(ctx, "apple", "sub", "")
	if _, err := store.AddDevice(ctx, user.ID, "Mac", deviceKey(1)); err != nil {
		t.Fatal(err)
	}
	// Rebuild the devices table as version 1 had it.
	for _, statement := range []string{
		`DROP INDEX devices_revoked_refresh`,
		`DROP INDEX devices_revoked_previous_refresh`,
		`ALTER TABLE devices DROP COLUMN revoked_access_hash`,
		`ALTER TABLE devices DROP COLUMN revoked_refresh_hash`,
		`ALTER TABLE devices DROP COLUMN revoked_previous_refresh_hash`,
		`PRAGMA user_version = 1`,
	} {
		if _, err := store.db.Exec(statement); err != nil {
			t.Fatal(statement, err)
		}
	}
	store.Close()
	again, err := Open(dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	var version int
	if err := again.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 2 {
		t.Fatal(version, err)
	}
	devices, err := again.Devices(ctx, 0)
	if err != nil || len(devices) != 1 {
		t.Fatal(devices, err)
	}
	if _, err := again.db.Exec(`UPDATE devices SET revoked_access_hash = x'00'`); err == nil {
		t.Fatal("revoked_access_hash must be 32 bytes")
	}
}
