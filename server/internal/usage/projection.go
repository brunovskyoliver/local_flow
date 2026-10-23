package usage

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"unicode"
	"unicode/utf8"
)

// Batch is the internal source-to-projection boundary. No inference account ID,
// email, OIDC subject or token is serialized. Only the source creates controls.
type Batch struct {
	Installation string     `json:"installation"`
	Control      Control    `json:"control"`
	Rows         []Row      `json:"rows"`
	Directory    *Directory `json:"directory,omitempty"`
}

// Pending returns controls before data and limits each page without an event
// outbox. A disabled current control is still exportable to remove prior grants.
func (s *Store) Pending(ctx context.Context, installation string) ([]Batch, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !uuidPattern.MatchString(installation) {
		return nil, ErrInvalid
	}
	rows, err := s.db.QueryContext(ctx, "SELECT "+controlColumns+" FROM controls WHERE revision>ack ORDER BY device LIMIT 100")
	if err != nil {
		return nil, err
	}
	out := []Batch{}
	for rows.Next() {
		c, e := scanControl(rows)
		if e != nil {
			rows.Close()
			return nil, e
		}
		out = append(out, Batch{Installation: installation, Control: c, Rows: []Row{}})
	}
	err = rows.Err()
	rows.Close()
	if err != nil || len(out) > 0 {
		return out, err
	}
	var device int64
	var c Control
	err = s.db.QueryRowContext(ctx, "SELECT c.device,"+qualifiedControls+" FROM controls c WHERE enabled=1 AND EXISTS(SELECT 1 FROM daily d WHERE d.device=c.device AND d.epoch=c.epoch AND d.revision>d.exported AND d.day>=?) ORDER BY c.device LIMIT 1", s.cutoff()).Scan(&device, &c.UserID, &c.DeviceID, &c.Epoch, &c.Grant, &c.Enabled, &c.Revision, &c.DeletionCutoff, &c.Ack)
	if errors.Is(err, sql.ErrNoRows) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	r, err := s.db.QueryContext(ctx, "SELECT day,revision,local_count,remote_count,local_audio_ms,remote_audio_ms,coverage FROM daily WHERE device=? AND epoch=? AND revision>exported AND day>=? ORDER BY day LIMIT 100", device, c.Epoch, s.cutoff())
	if err != nil {
		return nil, err
	}
	defer r.Close()
	b := Batch{Installation: installation, Control: c, Rows: []Row{}}
	for r.Next() {
		var row Row
		if err = r.Scan(&row.Day, &row.Revision, &row.LocalCount, &row.RemoteCount, &row.LocalAudioMS, &row.RemoteAudioMS, &row.Coverage); err != nil {
			return nil, err
		}
		b.Rows = append(b.Rows, row)
	}
	return append(out, b), r.Err()
}

const qualifiedControls = "c.user_uuid,c.device_uuid,c.epoch,c.grant_id,c.enabled,c.revision,c.deletion_cutoff,c.ack"

// AcknowledgeRows never clears a concurrently updated row's export obligation.
func (s *Store) AcknowledgeRows(ctx context.Context, b Batch) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, row := range b.Rows {
		_, err = tx.ExecContext(ctx, `UPDATE daily SET exported=max(exported,?) WHERE device=(SELECT device FROM controls WHERE device_uuid=? AND epoch=? AND revision=?) AND epoch=? AND day=? AND revision>=?`, row.Revision, b.Control.DeviceID, b.Control.Epoch, b.Control.Revision, b.Control.Epoch, row.Day, row.Revision)
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

type Directory struct {
	Label    string `json:"label"`
	Revision uint64 `json:"revision"`
	Removed  bool   `json:"removed"`
}

func (b Batch) Validate() error {
	c := b.Control
	if !uuidPattern.MatchString(b.Installation) || !uuidPattern.MatchString(c.UserID) || !uuidPattern.MatchString(c.DeviceID) || c.Epoch == 0 || c.Epoch > math.MaxInt64 || c.Revision == 0 || c.Revision > math.MaxInt64 || c.DeletionCutoff >= c.Epoch || len(b.Rows) > 100 {
		return ErrInvalid
	}
	if c.Enabled && !uuidPattern.MatchString(c.Grant) || !c.Enabled && c.Grant != "" {
		return ErrInvalid
	}
	seen := map[string]bool{}
	for _, r := range b.Rows {
		if r.Valid() != nil || seen[r.Day] {
			return ErrInvalid
		}
		seen[r.Day] = true
	}
	if b.Directory != nil {
		d := b.Directory
		if len(d.Label) > 512 || utf8.RuneCountInString(d.Label) > 128 || d.Revision == 0 || d.Revision > math.MaxInt64 {
			return ErrInvalid
		}
		for _, r := range d.Label {
			if unicode.IsControl(r) {
				return ErrInvalid
			}
		}
	}
	return nil
}
func (s *Store) AcknowledgeControl(ctx context.Context, b Batch) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.ExecContext(ctx, "UPDATE controls SET ack=? WHERE device_uuid=? AND revision=? AND epoch=?", b.Control.Revision, b.Control.DeviceID, b.Control.Revision, b.Control.Epoch)
	return err
}

// Current refuses a queued snapshot after a newer source control or revocation.
func (s *Store) Current(ctx context.Context, b Batch) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	var user, device int64
	var c Control
	err := s.db.QueryRowContext(ctx, "SELECT user,device,"+controlColumns+" FROM controls WHERE device_uuid=?", b.Control.DeviceID).Scan(&user, &device, &c.UserID, &c.DeviceID, &c.Epoch, &c.Grant, &c.Enabled, &c.Revision, &c.DeletionCutoff, &c.Ack)
	return err == nil && c.UserID == b.Control.UserID && c.Epoch == b.Control.Epoch && c.Revision == b.Control.Revision && (len(b.Rows) == 0 || (c.Enabled && s.cfg.Approved != nil && s.cfg.Approved(Identity{user, device})))
}
