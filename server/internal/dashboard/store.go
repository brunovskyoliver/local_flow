package dashboard

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"localflow/server/internal/usage"
	_ "modernc.org/sqlite"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Projection applies each source control and its snapshots in one transaction.
// The latest epoch/cutoff survives deletion, so delayed exports cannot resurrect.
type Projection struct {
	mu  sync.Mutex
	db  *sql.DB
	now func() time.Time
}

func Open(path string, now func() time.Time) (*Projection, error) {
	if now == nil {
		now = time.Now
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
		return nil, errors.New("dashboard: database permissions")
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	var version int
	if err = db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version > 2 {
		db.Close()
		return nil, errors.New("dashboard: unsupported database schema")
	}
	if err = migrateDashboard(db, version); err != nil {
		db.Close()
		return nil, err
	}
	p := &Projection{db: db, now: now}
	if err = p.Purge(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	return p, nil
}
func (p *Projection) Close() error   { return p.db.Close() }
func (p *Projection) cutoff() string { return p.now().UTC().AddDate(0, 0, -89).Format("2006-01-02") }
func (p *Projection) Purge(ctx context.Context) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "DELETE FROM daily WHERE day<?", p.cutoff()); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM controls WHERE enabled=0 AND changed<? AND NOT EXISTS(SELECT 1 FROM daily WHERE daily.installation=controls.installation AND daily.device=controls.device) AND NOT EXISTS(SELECT 1 FROM deletion_requests q WHERE q.installation=controls.installation AND q.user=controls.user)", p.now().AddDate(0, 0, -90).Unix()); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM directory WHERE NOT EXISTS(SELECT 1 FROM daily WHERE daily.installation=directory.installation AND daily.user=directory.user)"); err != nil {
		return err
	}
	return tx.Commit()
}
func (p *Projection) Apply(ctx context.Context, b usage.Batch) error {
	if err := b.Validate(); err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "DELETE FROM daily WHERE day<?", p.cutoff()); err != nil {
		return err
	}
	var old usage.Control
	err = tx.QueryRowContext(ctx, "SELECT user,epoch,revision,cutoff,enabled,grant_id FROM controls WHERE installation=? AND device=?", b.Installation, b.Control.DeviceID).Scan(&old.UserID, &old.Epoch, &old.Revision, &old.DeletionCutoff, &old.Enabled, &old.Grant)
	c := b.Control
	if err == nil {
		if old.UserID != c.UserID || c.Epoch < old.Epoch || c.Revision < old.Revision || c.DeletionCutoff < old.DeletionCutoff {
			return usage.ErrRevoked
		}
		if c.Revision == old.Revision && (c.Epoch != old.Epoch || c.Enabled != old.Enabled || c.Grant != old.Grant || c.DeletionCutoff != old.DeletionCutoff) {
			return usage.ErrInvalid
		}
	} else if errors.Is(err, sql.ErrNoRows) {
		var slots, users, devices int
		var exists bool
		if err = tx.QueryRowContext(ctx, "SELECT count(*),count(DISTINCT installation||':'||user) FROM controls").Scan(&slots, &users); err != nil {
			return err
		}
		if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM controls WHERE installation=? AND user=?", b.Installation, c.UserID).Scan(&devices); err != nil {
			return err
		}
		exists = devices > 0
		if slots >= 1000 || devices >= 10 || (!exists && users >= 100) {
			return usage.ErrBusy
		}
	} else {
		return err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO controls VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(installation,device) DO UPDATE SET epoch=excluded.epoch,revision=excluded.revision,cutoff=excluded.cutoff,enabled=excluded.enabled,grant_id=excluded.grant_id,changed=CASE WHEN excluded.revision>controls.revision THEN excluded.changed ELSE controls.changed END`, b.Installation, c.DeviceID, c.UserID, c.Epoch, c.Revision, c.DeletionCutoff, c.Enabled, c.Grant, p.now().Unix()); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM daily WHERE installation=? AND device=? AND epoch<=?", b.Installation, c.DeviceID, c.DeletionCutoff); err != nil {
		return err
	}
	if len(b.Rows) > 0 && (!c.Enabled || c.Epoch <= c.DeletionCutoff) {
		return usage.ErrRevoked
	}
	for _, r := range b.Rows {
		if r.Day < p.cutoff() || r.Day > p.now().UTC().AddDate(0, 0, 1).Format("2006-01-02") {
			return usage.ErrInvalid
		}
		oldRow := usage.Row{Day: r.Day}
		err = tx.QueryRowContext(ctx, "SELECT revision,local_count,remote_count,local_audio_ms,remote_audio_ms,coverage FROM daily WHERE installation=? AND device=? AND epoch=? AND day=?", b.Installation, c.DeviceID, c.Epoch, r.Day).Scan(&oldRow.Revision, &oldRow.LocalCount, &oldRow.RemoteCount, &oldRow.LocalAudioMS, &oldRow.RemoteAudioMS, &oldRow.Coverage)
		if err == nil {
			if r.Revision < oldRow.Revision {
				continue
			}
			if r.Revision == oldRow.Revision {
				if r != oldRow {
					return usage.ErrInvalid
				}
				continue
			}
			if r.LocalCount < oldRow.LocalCount || r.RemoteCount < oldRow.RemoteCount || r.LocalAudioMS < oldRow.LocalAudioMS || r.RemoteAudioMS < oldRow.RemoteAudioMS || (oldRow.Coverage == "partial" && r.Coverage != "partial") {
				return usage.ErrInvalid
			}
		} else if errors.Is(err, sql.ErrNoRows) {
			var n int
			if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM daily").Scan(&n); err != nil {
				return err
			}
			if n >= usage.MaxRows {
				return usage.ErrBusy
			}
		} else {
			return err
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO daily VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(installation,device,epoch,day) DO UPDATE SET revision=excluded.revision,local_count=excluded.local_count,remote_count=excluded.remote_count,local_audio_ms=excluded.local_audio_ms,remote_audio_ms=excluded.remote_audio_ms,coverage=excluded.coverage,reported=excluded.reported`, b.Installation, c.DeviceID, c.UserID, c.Epoch, r.Day, r.Revision, r.LocalCount, r.RemoteCount, r.LocalAudioMS, r.RemoteAudioMS, r.Coverage, p.now().Unix())
		if err != nil {
			return err
		}
	}
	// Keep per-user/day totals representable; SQLite reports checked SUM overflow.
	for _, r := range b.Rows {
		var count, audio sql.NullInt64
		if e := tx.QueryRowContext(ctx, "SELECT sum(local_count+remote_count),sum(local_audio_ms+remote_audio_ms) FROM daily WHERE installation=? AND user=? AND day=?", b.Installation, c.UserID, r.Day).Scan(&count, &audio); e != nil {
			return usage.ErrInvalid
		}
	}
	if b.Directory != nil {
		d := b.Directory
		if d.Removed {
			if _, err = tx.ExecContext(ctx, "DELETE FROM directory WHERE installation=? AND user=? AND NOT EXISTS(SELECT 1 FROM daily WHERE installation=? AND user=?)", b.Installation, c.UserID, b.Installation, c.UserID); err != nil {
				return err
			}
		} else {
			if _, err = tx.ExecContext(ctx, `INSERT INTO directory VALUES(?,?,?,?) ON CONFLICT(installation,user) DO UPDATE SET label=excluded.label,revision=max(directory.revision,excluded.revision) WHERE excluded.revision>=directory.revision`, b.Installation, c.UserID, d.Label, d.Revision); err != nil {
				return err
			}
		}
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM directory WHERE NOT EXISTS(SELECT 1 FROM daily WHERE daily.installation=directory.installation AND daily.user=directory.user)"); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM deletion_requests WHERE NOT EXISTS(SELECT 1 FROM daily WHERE daily.installation=deletion_requests.installation AND daily.user=deletion_requests.user) AND NOT EXISTS(SELECT 1 FROM controls WHERE controls.installation=deletion_requests.installation AND controls.user=deletion_requests.user AND (enabled=1 OR cutoff=0))"); err != nil {
		return err
	}
	return tx.Commit()
}

type ViewRow struct {
	UserID          string
	DeletionPending bool
	User            string
	Day             string
	Local           int64
	Remote          int64
	AudioMS         int64
	Coverage        string
	Reported        string
	Freshness       string
}

func (p *Projection) Rows(ctx context.Context) ([]ViewRow, error) { return p.RowsPage(ctx, 0, 1000) }
func (p *Projection) RowsPage(ctx context.Context, offset, limit int) ([]ViewRow, error) {
	if offset < 0 || offset > 9000 || limit < 1 || limit > 1000 {
		return nil, usage.ErrInvalid
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	rows, err := p.db.QueryContext(ctx, `SELECT d.user,exists(SELECT 1 FROM deletion_requests q WHERE q.installation=d.installation AND q.user=d.user),coalesce(n.label,'User '||substr(d.user,1,8)),d.day,sum(d.local_count),sum(d.remote_count),sum(d.local_audio_ms+d.remote_audio_ms),CASE WHEN max(CASE WHEN d.coverage='partial' THEN 1 ELSE 0 END)=1 THEN 'partial' ELSE 'complete' END,max(d.reported) FROM daily d LEFT JOIN directory n ON n.installation=d.installation AND n.user=d.user WHERE d.day>=? GROUP BY d.installation,d.user,d.day ORDER BY d.day DESC,d.user LIMIT ? OFFSET ?`, p.cutoff(), limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ViewRow{}
	for rows.Next() {
		var r ViewRow
		var unix int64
		if err = rows.Scan(&r.UserID, &r.DeletionPending, &r.User, &r.Day, &r.Local, &r.Remote, &r.AudioMS, &r.Coverage, &unix); err != nil {
			return nil, err
		}
		r.Reported = time.Unix(unix, 0).UTC().Format("2006-01-02 15:04 UTC")
		r.Freshness = "Received recently"
		if p.now().Sub(time.Unix(unix, 0)) > 24*time.Hour {
			r.Freshness = "Report older than 24 hours"
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (r ViewRow) Duration() string {
	seconds := r.AudioMS / 1000
	if seconds >= 3600 {
		return fmt.Sprintf("%dh %dm %ds", seconds/3600, (seconds%3600)/60, seconds%60)
	}
	if seconds >= 60 {
		return fmt.Sprintf("%dm %ds", seconds/60, seconds%60)
	}
	return fmt.Sprintf("%ds", seconds)
}
func (r ViewRow) CoverageLabel() string {
	if r.Coverage == "partial" {
		return "Partial"
	}
	return "Complete"
}

func migrateDashboard(db *sql.DB, version int) error {
	if _, err := db.Exec("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=1000; PRAGMA max_page_count=32768;"); err != nil {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if version == 1 {
		if _, err = tx.Exec("ALTER TABLE controls ADD COLUMN changed INTEGER NOT NULL DEFAULT 0;"); err != nil {
			return err
		}
	}
	if _, err = tx.Exec(`CREATE TABLE IF NOT EXISTS controls(installation TEXT NOT NULL,device TEXT NOT NULL,user TEXT NOT NULL,epoch INTEGER NOT NULL,revision INTEGER NOT NULL,cutoff INTEGER NOT NULL,enabled INTEGER NOT NULL,grant_id TEXT NOT NULL,changed INTEGER NOT NULL,PRIMARY KEY(installation,device));
 CREATE TABLE IF NOT EXISTS daily(installation TEXT NOT NULL,device TEXT NOT NULL,user TEXT NOT NULL,epoch INTEGER NOT NULL,day TEXT NOT NULL,revision INTEGER NOT NULL,local_count INTEGER NOT NULL,remote_count INTEGER NOT NULL,local_audio_ms INTEGER NOT NULL,remote_audio_ms INTEGER NOT NULL,coverage TEXT NOT NULL,reported INTEGER NOT NULL,PRIMARY KEY(installation,device,epoch,day));
 CREATE INDEX IF NOT EXISTS daily_day ON daily(day);
 CREATE TABLE IF NOT EXISTS directory(installation TEXT NOT NULL,user TEXT NOT NULL,label TEXT NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(installation,user));
 CREATE TABLE IF NOT EXISTS deletion_requests(installation TEXT NOT NULL,user TEXT NOT NULL,PRIMARY KEY(installation,user));
 PRAGMA user_version=2;`); err != nil {
		return err
	}
	return tx.Commit()
}
