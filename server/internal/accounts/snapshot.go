package accounts

import (
	"context"
	"database/sql"
	"slices"
	"sync"
	"sync/atomic"
	"time"
)

// PollInterval is how often the running flowd checks PRAGMA data_version, so
// an admin change from another process takes effect within 250 ms (R9).
const PollInterval = 250 * time.Millisecond

// SnapshotDevice is a device as the snapshot holds it.
type SnapshotDevice struct {
	ID                  int64
	UserID              int64
	State               DeviceState
	PublicKey           []byte
	RefreshHash         []byte
	PreviousRefreshHash []byte
	AccessHash          []byte
	AccessExpiresAt     time.Time
}

// Snapshot is an immutable in-memory copy of user and device states, public
// keys and token hashes. The listener authenticates from it without touching
// SQLite.
type Snapshot struct {
	users   map[int64]UserState
	devices map[int64]SnapshotDevice
	access  map[[32]byte]int64
	// revoked maps the last access token hash of each revoked device.
	revoked map[[32]byte]int64
}

// Principal is the user and device an access token belongs to.
type Principal struct {
	UserID   int64
	DeviceID int64
}

// User returns a user's state.
func (s *Snapshot) User(id int64) (UserState, bool) {
	state, ok := s.users[id]
	return state, ok
}

// Device returns one device.
func (s *Snapshot) Device(id int64) (SnapshotDevice, bool) {
	device, ok := s.devices[id]
	return device, ok
}

// Approved reports whether both the user and the device are approved and the
// device belongs to the user.
func (s *Snapshot) Approved(userID, deviceID int64) bool {
	device, ok := s.devices[deviceID]
	return ok && device.UserID == userID && device.State == DeviceApproved && s.users[userID] == UserApproved
}

// Authenticate resolves an access token by the server clock: unknown is
// ErrUnauthorized, a revoked user or device ErrRevoked, any other unapproved
// state ErrNotApproved, and a token at or past expiry ErrTokenExpired. The
// last access token of a device that is still revoked is ErrRevoked.
func (s *Snapshot) Authenticate(accessToken string, now time.Time) (Principal, error) {
	hash := HashToken(accessToken)
	id, ok := s.access[hash]
	if !ok {
		if id, ok := s.revoked[hash]; ok && s.devices[id].State == DeviceRevoked {
			return Principal{}, ErrRevoked
		}
		return Principal{}, ErrUnauthorized
	}
	device := s.devices[id]
	user := s.users[device.UserID]
	switch {
	case user == UserRevoked || device.State == DeviceRevoked:
		return Principal{}, ErrRevoked
	case user != UserApproved || device.State != DeviceApproved:
		return Principal{}, ErrNotApproved
	case !now.Before(device.AccessExpiresAt):
		return Principal{}, ErrTokenExpired
	}
	return Principal{UserID: device.UserID, DeviceID: id}, nil
}

// Lost lists the users and devices that were approved in the previous
// snapshot and are not any more.
type Lost struct {
	Users   []int64
	Devices []int64
}

// Watcher keeps the current snapshot. It polls PRAGMA data_version on a
// dedicated connection, which changes only when another connection commits,
// and reloads on change.
type Watcher struct {
	conn    *sql.Conn
	onLost  func(Lost)
	current atomic.Pointer[Snapshot]
	mu      sync.Mutex // serializes Poll
	version int64
}

// Watch loads the first snapshot. onLost (may be nil) is called from Poll with
// every user and device that stopped being approved.
func (s *Store) Watch(ctx context.Context, onLost func(Lost)) (*Watcher, error) {
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	w := &Watcher{conn: conn, onLost: onLost}
	if err := conn.QueryRowContext(ctx, "PRAGMA data_version").Scan(&w.version); err != nil {
		conn.Close()
		return nil, err
	}
	snapshot, err := w.load(ctx)
	if err != nil {
		conn.Close()
		return nil, err
	}
	w.current.Store(snapshot)
	return w, nil
}

// Snapshot returns the current snapshot.
func (w *Watcher) Snapshot() *Snapshot { return w.current.Load() }

// Close releases the dedicated connection.
func (w *Watcher) Close() error { return w.conn.Close() }

// Run polls on every tick until ctx ends. Production passes a
// time.Ticker(PollInterval) channel; tests pass their own.
func (w *Watcher) Run(ctx context.Context, ticks <-chan time.Time) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticks:
			_, _ = w.Poll(ctx)
		}
	}
}

// Poll reloads the snapshot when data_version changed and reports whether it
// did.
func (w *Watcher) Poll(ctx context.Context) (bool, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	var version int64
	if err := w.conn.QueryRowContext(ctx, "PRAGMA data_version").Scan(&version); err != nil {
		return false, err
	}
	if version == w.version {
		return false, nil
	}
	// The version is read before loading, so a commit that lands during the
	// load is seen by the next poll.
	next, err := w.load(ctx)
	if err != nil {
		return false, err
	}
	w.version = version
	previous := w.current.Swap(next)
	if lost := lostApproval(previous, next); w.onLost != nil && (len(lost.Users) > 0 || len(lost.Devices) > 0) {
		w.onLost(lost)
	}
	return true, nil
}

// load reads users and devices in one statement, so the snapshot is a
// consistent read.
func (w *Watcher) load(ctx context.Context) (*Snapshot, error) {
	rows, err := w.conn.QueryContext(ctx, `SELECT u.id, u.state, d.id, d.state, d.public_key, d.refresh_hash,
		d.previous_refresh_hash, d.access_hash, d.access_expires_at, d.revoked_access_hash FROM users u LEFT JOIN devices d ON d.user_id = u.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	s := &Snapshot{users: map[int64]UserState{}, devices: map[int64]SnapshotDevice{}, access: map[[32]byte]int64{},
		revoked: map[[32]byte]int64{}}
	for rows.Next() {
		var userID int64
		var userState string
		var deviceID, accessExpires sql.NullInt64
		var deviceState sql.NullString
		var d SnapshotDevice
		var revokedAccess []byte
		if err := rows.Scan(&userID, &userState, &deviceID, &deviceState, &d.PublicKey, &d.RefreshHash,
			&d.PreviousRefreshHash, &d.AccessHash, &accessExpires, &revokedAccess); err != nil {
			return nil, err
		}
		s.users[userID] = UserState(userState)
		if !deviceID.Valid {
			continue
		}
		d.ID, d.UserID, d.State, d.AccessExpiresAt = deviceID.Int64, userID, DeviceState(deviceState.String), fromMillis(accessExpires)
		s.devices[d.ID] = d
		if len(d.AccessHash) == 32 {
			s.access[[32]byte(d.AccessHash)] = d.ID
		}
		if len(revokedAccess) == 32 {
			s.revoked[[32]byte(revokedAccess)] = d.ID
		}
	}
	return s, rows.Err()
}

func lostApproval(previous, next *Snapshot) Lost {
	var lost Lost
	for id, state := range previous.users {
		if state == UserApproved && next.users[id] != UserApproved {
			lost.Users = append(lost.Users, id)
		}
	}
	for id, device := range previous.devices {
		if device.State == DeviceApproved && next.devices[id].State != DeviceApproved {
			lost.Devices = append(lost.Devices, id)
		}
	}
	slices.Sort(lost.Users)
	slices.Sort(lost.Devices)
	return lost
}
