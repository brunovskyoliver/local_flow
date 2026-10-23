package usage

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

type Identity struct {
	User   int64
	Device int64
}
type Config struct {
	Now              func() time.Time
	Approved         func(Identity) bool
	MaxSlots         int
	MaxAggregateRows int
}
type Store struct {
	mu  sync.Mutex
	db  *sql.DB
	cfg Config
}
type Control struct {
	UserID         string `json:"user_id"`
	DeviceID       string `json:"device_id"`
	Epoch          uint64 `json:"epoch"`
	Grant          string `json:"grant,omitempty"`
	Enabled        bool   `json:"enabled"`
	Revision       uint64 `json:"revision"`
	DeletionCutoff uint64 `json:"deletion_cutoff"`
	Ack            uint64 `json:"-"`
}

const schema = `
CREATE TABLE IF NOT EXISTS controls (
 device INTEGER PRIMARY KEY, user INTEGER NOT NULL, user_uuid TEXT NOT NULL, device_uuid TEXT NOT NULL UNIQUE,
 epoch INTEGER NOT NULL, grant_id TEXT NOT NULL, enabled INTEGER NOT NULL,
 revision INTEGER NOT NULL, deletion_cutoff INTEGER NOT NULL, ack INTEGER NOT NULL DEFAULT 0,
 changed INTEGER NOT NULL,previous_grant TEXT NOT NULL DEFAULT '',previous_epoch INTEGER NOT NULL DEFAULT 0,user_delete_epoch INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS controls_user ON controls(user);
CREATE TABLE IF NOT EXISTS daily (
 device INTEGER NOT NULL REFERENCES controls(device), epoch INTEGER NOT NULL, day TEXT NOT NULL,
 revision INTEGER NOT NULL, local_count INTEGER NOT NULL, remote_count INTEGER NOT NULL,
 local_audio_ms INTEGER NOT NULL, remote_audio_ms INTEGER NOT NULL, coverage TEXT NOT NULL,
 exported INTEGER NOT NULL DEFAULT 0, reported INTEGER NOT NULL,
 PRIMARY KEY(device,epoch,day));
CREATE INDEX IF NOT EXISTS daily_day ON daily(day);
PRAGMA user_version=3;`

func Open(path string, cfg Config) (*Store, error) {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.MaxSlots == 0 {
		cfg.MaxSlots = MaxDevices
	}
	if cfg.MaxAggregateRows == 0 {
		cfg.MaxAggregateRows = MaxRows
	}
	if cfg.MaxSlots < 1 || cfg.MaxSlots > MaxDevices || cfg.MaxAggregateRows < 1 || cfg.MaxAggregateRows > MaxRows {
		return nil, ErrInvalid
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	info, err := f.Stat()
	f.Close()
	if err != nil {
		return nil, err
	}
	if info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("usage: database permissions")
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	fail := func(err error) (*Store, error) { db.Close(); return nil, err }
	var version int
	if err = db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return fail(err)
	}
	if version > 3 {
		return fail(errors.New("usage: newer schema"))
	}
	// DELETE journaling bounds the journal by the 128 MiB database ceiling. A
	// separate 129 MiB journal allowance must be reserved by deployment.
	if _, err = db.Exec(`PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=1000; PRAGMA max_page_count=32768;`); err != nil {
		return fail(err)
	}
	if err = migrateStore(db, version); err != nil {
		return fail(err)
	}
	s := &Store{db: db, cfg: cfg}
	if err = s.Purge(context.Background()); err != nil {
		return fail(err)
	}
	return s, nil
}
func (s *Store) Close() error { return s.db.Close() }
func randomID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("usage: entropy unavailable")
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	h := hex.EncodeToString(b[:])
	return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}
func (s *Store) cutoff() string { return s.cfg.Now().UTC().AddDate(0, 0, -89).Format("2006-01-02") }
func (s *Store) Purge(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "DELETE FROM daily WHERE day < ?", s.cutoff()); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM controls WHERE enabled=0 AND ack>=revision AND changed<? AND NOT EXISTS(SELECT 1 FROM daily WHERE daily.device=controls.device)", s.cfg.Now().AddDate(0, 0, -90).Unix()); err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Store) Run(ctx context.Context) {
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_ = s.Purge(ctx)
			_ = s.Reconcile(ctx)
		}
	}
}
func scanControl(row interface{ Scan(...any) error }) (c Control, err error) {
	err = row.Scan(&c.UserID, &c.DeviceID, &c.Epoch, &c.Grant, &c.Enabled, &c.Revision, &c.DeletionCutoff, &c.Ack)
	return
}

const controlColumns = "user_uuid,device_uuid,epoch,grant_id,enabled,revision,deletion_cutoff,ack"

func getControl(ctx context.Context, tx *sql.Tx, id Identity) (Control, error) {
	return scanControl(tx.QueryRowContext(ctx, "SELECT "+controlColumns+" FROM controls WHERE device=? AND user=?", id.Device, id.User))
}
func response(c Control, status string) Response {
	r := Response{Version: 1, Status: status, UserID: c.UserID, DeviceID: c.DeviceID, Epoch: c.Epoch, Enabled: c.Enabled, ControlRevision: c.Revision, DeletionCutoff: c.DeletionCutoff, PropagationPending: c.Ack < c.Revision, Rows: []Ack{}}
	if c.Enabled {
		r.Grant = c.Grant
	}
	return r
}
func (s *Store) Handle(ctx context.Context, id Identity, r Request) (Response, error) {
	if id.User <= 0 || id.Device <= 0 {
		return response(Control{}, "revoked"), nil
	}
	if err := r.Validate(); err != nil {
		return response(Control{}, "invalid"), nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cfg.Approved == nil || !s.cfg.Approved(id) {
		return response(Control{}, "revoked"), nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Response{}, err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "DELETE FROM daily WHERE day < ?", s.cutoff()); err != nil {
		return Response{}, err
	}
	c, err := getControl(ctx, tx, id)
	if errors.Is(err, sql.ErrNoRows) {
		if r.Action != "enable" {
			if r.Action == "snapshot" || r.Action == "withdraw" || r.Action == "delete_device" || r.Action == "delete_user" {
				return response(Control{}, "revoked"), nil
			}
			return response(Control{}, "accepted"), nil
		}
		var total, users, devices int
		var userID string
		if err = tx.QueryRowContext(ctx, "SELECT count(*),count(DISTINCT user) FROM controls").Scan(&total, &users); err != nil {
			return Response{}, err
		}
		if err = tx.QueryRowContext(ctx, "SELECT count(*),coalesce(max(user_uuid),'') FROM controls WHERE user=?", id.User).Scan(&devices, &userID); err != nil {
			return Response{}, err
		}
		if total >= s.cfg.MaxSlots || devices >= 10 || (devices == 0 && users >= MaxUsers) {
			return response(Control{}, "busy"), nil
		}
		if userID == "" {
			userID = randomID()
		}
		c = Control{UserID: userID, DeviceID: randomID()}
		_, err = tx.ExecContext(ctx, "INSERT INTO controls(device,user,user_uuid,device_uuid,epoch,grant_id,enabled,revision,deletion_cutoff,changed) VALUES(?,?,?,?,0,'',0,0,0,?)", id.Device, id.User, c.UserID, c.DeviceID, s.cfg.Now().Unix())
	}
	if err != nil {
		return Response{}, err
	}
	if r.Action == "withdraw" || r.Action == "delete_device" || r.Action == "delete_user" {
		valid := c.Enabled && r.Epoch == c.Epoch && r.Grant == c.Grant
		if !c.Enabled {
			var previousGrant string
			var previousEpoch uint64
			if e := tx.QueryRowContext(ctx, "SELECT previous_grant,previous_epoch FROM controls WHERE device=? AND user=?", id.Device, id.User).Scan(&previousGrant, &previousEpoch); e != nil {
				return Response{}, e
			}
			valid = previousEpoch == r.Epoch && previousGrant == r.Grant
		}
		if !valid {
			return stateResponse(ctx, tx, id, c, "revoked"), nil
		}
	}
	switch r.Action {
	case "enable":
		if c.Enabled {
			return stateResponse(ctx, tx, id, c, "duplicate"), tx.Commit()
		}
		// A pending deletion must reach the dashboard before a fresh grant.
		if c.DeletionCutoff > 0 && c.Ack < c.Revision {
			return stateResponse(ctx, tx, id, c, "busy"), nil
		}
		if err = advance(&c, true, false); err != nil {
			return stateResponse(ctx, tx, id, c, "busy"), nil
		}
		err = saveControl(ctx, tx, id.Device, c, s.cfg.Now())
	case "withdraw", "delete_device":
		if r.Action == "delete_device" && !c.Enabled && c.DeletionCutoff >= r.Epoch {
			return stateResponse(ctx, tx, id, c, "duplicate"), tx.Commit()
		}
		if !c.Enabled && r.Action == "withdraw" {
			return stateResponse(ctx, tx, id, c, "duplicate"), tx.Commit()
		}
		if err = advance(&c, false, r.Action == "delete_device"); err != nil {
			return stateResponse(ctx, tx, id, c, "busy"), nil
		}
		err = saveControl(ctx, tx, id.Device, c, s.cfg.Now())
		if err == nil && r.Action == "delete_device" {
			_, err = tx.ExecContext(ctx, "DELETE FROM daily WHERE device=? AND epoch<=?", id.Device, c.DeletionCutoff)
		}
	case "delete_user":
		var deletedEpoch uint64
		if e := tx.QueryRowContext(ctx, "SELECT user_delete_epoch FROM controls WHERE device=?", id.Device).Scan(&deletedEpoch); e != nil {
			return Response{}, e
		}
		if !c.Enabled && deletedEpoch >= r.Epoch {
			return stateResponse(ctx, tx, id, c, "duplicate"), tx.Commit()
		}
		rows, e := tx.QueryContext(ctx, "SELECT device,"+controlColumns+" FROM controls WHERE user=?", id.User)
		if e != nil {
			return Response{}, e
		}
		type item struct {
			device int64
			c      Control
		}
		items := []item{}
		for rows.Next() {
			var v item
			if e = rows.Scan(&v.device, &v.c.UserID, &v.c.DeviceID, &v.c.Epoch, &v.c.Grant, &v.c.Enabled, &v.c.Revision, &v.c.DeletionCutoff, &v.c.Ack); e != nil {
				rows.Close()
				return Response{}, e
			}
			items = append(items, v)
		}
		e = rows.Err()
		rows.Close()
		if e != nil {
			return Response{}, e
		}
		for _, v := range items {
			if e = advance(&v.c, false, true); e != nil {
				return stateResponse(ctx, tx, id, c, "busy"), nil
			}
			if e = saveControl(ctx, tx, v.device, v.c, s.cfg.Now()); e != nil {
				return Response{}, e
			}
			if _, e = tx.ExecContext(ctx, "DELETE FROM daily WHERE device=? AND epoch<=?", v.device, v.c.DeletionCutoff); e != nil {
				return Response{}, e
			}
			if v.device == id.Device {
				c = v.c
			}
		}
		_, err = tx.ExecContext(ctx, "UPDATE controls SET user_delete_epoch=? WHERE device=?", r.Epoch, id.Device)
	case "snapshot":
		if !c.Enabled || r.Epoch != c.Epoch || r.Grant != c.Grant {
			return stateResponse(ctx, tx, id, c, "revoked"), nil
		}
		acks, e := s.applyRows(ctx, tx, id.Device, r)
		if e != nil {
			if errors.Is(e, ErrInvalid) {
				return stateResponse(ctx, tx, id, c, "invalid"), nil
			}
			if errors.Is(e, ErrBusy) {
				return stateResponse(ctx, tx, id, c, "busy"), nil
			}
			return Response{}, e
		}
		out := stateResponse(ctx, tx, id, c, "accepted")
		out.Rows = acks
		if !s.cfg.Approved(id) {
			return stateResponse(ctx, tx, id, c, "revoked"), nil
		}
		return out, tx.Commit()
	case "status":
	}
	if err != nil {
		return Response{}, err
	}
	if !s.cfg.Approved(id) {
		return stateResponse(ctx, tx, id, c, "revoked"), nil
	}
	return stateResponse(ctx, tx, id, c, "accepted"), tx.Commit()
}
func advance(c *Control, enabled, erase bool) error {
	if c.Epoch >= math.MaxInt64 || c.Revision >= math.MaxInt64 || (enabled && c.Epoch >= math.MaxInt64-1) {
		return ErrBusy
	}
	if erase {
		c.DeletionCutoff = c.Epoch
	}
	c.Epoch++
	c.Revision++
	c.Enabled = enabled
	c.Grant = ""
	if enabled {
		c.Grant = randomID()
	}
	return nil
}
func saveControl(ctx context.Context, tx *sql.Tx, device int64, c Control, now time.Time) error {
	_, err := tx.ExecContext(ctx, "UPDATE controls SET previous_grant=CASE WHEN enabled=1 THEN grant_id ELSE previous_grant END,previous_epoch=CASE WHEN enabled=1 THEN epoch ELSE previous_epoch END,epoch=?,grant_id=?,enabled=?,revision=?,deletion_cutoff=?,changed=? WHERE device=?", c.Epoch, c.Grant, c.Enabled, c.Revision, c.DeletionCutoff, now.Unix(), device)
	return err
}
func (s *Store) applyRows(ctx context.Context, tx *sql.Tx, device int64, r Request) ([]Ack, error) {
	out := make([]Ack, 0, len(r.Rows))
	today := s.cfg.Now().UTC().AddDate(0, 0, 1).Format("2006-01-02")
	for _, row := range r.Rows {
		if row.Day < s.cutoff() || row.Day > today {
			return nil, ErrInvalid
		}
		var old Row
		old.Day = row.Day
		err := tx.QueryRowContext(ctx, "SELECT revision,local_count,remote_count,local_audio_ms,remote_audio_ms,coverage FROM daily WHERE device=? AND epoch=? AND day=?", device, r.Epoch, row.Day).Scan(&old.Revision, &old.LocalCount, &old.RemoteCount, &old.LocalAudioMS, &old.RemoteAudioMS, &old.Coverage)
		status := "accepted"
		if err == nil {
			if row.Revision < old.Revision {
				out = append(out, Ack{row.Day, old.Revision, "stale"})
				continue
			}
			if row.Revision == old.Revision {
				if row != old {
					return nil, ErrInvalid
				}
				out = append(out, Ack{row.Day, old.Revision, "duplicate"})
				continue
			}
			if row.LocalCount < old.LocalCount || row.RemoteCount < old.RemoteCount || row.LocalAudioMS < old.LocalAudioMS || row.RemoteAudioMS < old.RemoteAudioMS || (old.Coverage == "partial" && row.Coverage != "partial") {
				return nil, ErrInvalid
			}
		} else if errors.Is(err, sql.ErrNoRows) {
			var n int
			if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM daily").Scan(&n); err != nil {
				return nil, err
			}
			if n >= s.cfg.MaxAggregateRows {
				return nil, ErrBusy
			}
		} else {
			return nil, err
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO daily(device,epoch,day,revision,local_count,remote_count,local_audio_ms,remote_audio_ms,coverage,reported) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(device,epoch,day) DO UPDATE SET revision=excluded.revision,local_count=excluded.local_count,remote_count=excluded.remote_count,local_audio_ms=excluded.local_audio_ms,remote_audio_ms=excluded.remote_audio_ms,coverage=excluded.coverage,reported=excluded.reported`, device, r.Epoch, row.Day, row.Revision, row.LocalCount, row.RemoteCount, row.LocalAudioMS, row.RemoteAudioMS, row.Coverage, s.cfg.Now().Unix())
		if err != nil {
			return nil, err
		}
		out = append(out, Ack{row.Day, row.Revision, status})
	}
	return out, nil
}

// Reconcile advances grants whose verified account approval has been lost,
// including revocations made while flowd was stopped. Controls remain durable.
func (s *Store) Reconcile(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, "SELECT user,device,"+controlColumns+" FROM controls WHERE enabled=1")
	if err != nil {
		return err
	}
	type item struct {
		id Identity
		c  Control
	}
	items := []item{}
	for rows.Next() {
		var v item
		if err = rows.Scan(&v.id.User, &v.id.Device, &v.c.UserID, &v.c.DeviceID, &v.c.Epoch, &v.c.Grant, &v.c.Enabled, &v.c.Revision, &v.c.DeletionCutoff, &v.c.Ack); err != nil {
			rows.Close()
			return err
		}
		items = append(items, v)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, v := range items {
		if s.cfg.Approved == nil || !s.cfg.Approved(v.id) {
			if err = advance(&v.c, false, false); err != nil {
				return err
			}
			if err = saveControl(ctx, tx, v.id.Device, v.c, s.cfg.Now()); err != nil {
				return err
			}
		}
	}
	return tx.Commit()
}
func (s *Store) String() string {
	return fmt.Sprintf("usage store (capacity %d)", s.cfg.MaxAggregateRows)
}

func stateResponse(ctx context.Context, tx *sql.Tx, id Identity, c Control, status string) Response {
	r := response(c, status)
	if !c.Enabled {
		var deleted uint64
		if err := tx.QueryRowContext(ctx, "SELECT user_delete_epoch FROM controls WHERE device=?", id.Device).Scan(&deleted); err != nil {
			r.PropagationPending = true
		} else if deleted > 0 {
			var pending int
			if err := tx.QueryRowContext(ctx, "SELECT count(*) FROM controls WHERE user=? AND deletion_cutoff>0 AND ack<revision", id.User).Scan(&pending); err != nil || pending > 0 {
				r.PropagationPending = true
			}
		}
	}
	return r
}

func migrateStore(db *sql.DB, version int) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if version == 1 {
		if _, err = tx.Exec("ALTER TABLE controls ADD COLUMN previous_grant TEXT NOT NULL DEFAULT ''; ALTER TABLE controls ADD COLUMN previous_epoch INTEGER NOT NULL DEFAULT 0;"); err != nil {
			return err
		}
	}
	if version > 0 && version < 3 {
		if _, err = tx.Exec("ALTER TABLE controls ADD COLUMN user_delete_epoch INTEGER NOT NULL DEFAULT 0;"); err != nil {
			return err
		}
	}
	if _, err = tx.Exec(schema); err != nil {
		return err
	}
	return tx.Commit()
}
