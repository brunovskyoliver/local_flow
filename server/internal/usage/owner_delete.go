package usage

import "context"

// DeleteProjectedUser handles the authenticated owner's reporting-only control.
// It cannot change account approval, inference settings or client content.
func (s *Store) DeleteProjectedUser(ctx context.Context, user string) error {
	if !uuidPattern.MatchString(user) {
		return ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, "SELECT device,"+controlColumns+" FROM controls WHERE user_uuid=?", user)
	if err != nil {
		return err
	}
	type item struct {
		device int64
		c      Control
	}
	items := []item{}
	for rows.Next() {
		var v item
		if err = rows.Scan(&v.device, &v.c.UserID, &v.c.DeviceID, &v.c.Epoch, &v.c.Grant, &v.c.Enabled, &v.c.Revision, &v.c.DeletionCutoff, &v.c.Ack); err != nil {
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
		if !v.c.Enabled && v.c.DeletionCutoff >= v.c.Epoch-1 {
			continue
		}
		if err = advance(&v.c, false, true); err != nil {
			return err
		}
		if err = saveControl(ctx, tx, v.device, v.c, s.cfg.Now()); err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, "DELETE FROM daily WHERE device=? AND epoch<=?", v.device, v.c.DeletionCutoff); err != nil {
			return err
		}
	}
	return tx.Commit()
}
