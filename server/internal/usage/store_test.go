package usage

import (
	"context"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func testStore(t *testing.T, slots, rows int) (*Store, *atomic.Bool, *time.Time) {
	t.Helper()
	approved := new(atomic.Bool)
	approved.Store(true)
	now := time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)
	s, err := Open(filepath.Join(t.TempDir(), "usage.sqlite"), Config{Now: func() time.Time { return now }, Approved: func(Identity) bool { return approved.Load() }, MaxSlots: slots, MaxAggregateRows: rows})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s, approved, &now
}
func call(t *testing.T, s *Store, id Identity, r Request) Response {
	t.Helper()
	v, e := s.Handle(context.Background(), id, r)
	if e != nil {
		t.Fatal(e)
	}
	return v
}
func grant(t *testing.T, s *Store, id Identity) Response {
	return call(t, s, id, Request{Version: 1, Action: "enable"})
}
func snapshot(g Response, day string, n int64) Request {
	return Request{Version: 1, Action: "snapshot", Epoch: g.Epoch, Grant: g.Grant, Rows: []Row{{Day: day, Revision: uint64(n), LocalCount: n, LocalAudioMS: n * 1000, Coverage: "complete"}}}
}
func TestReplayAtomicityConsentAndAllEpochDeletion(t *testing.T) {
	s, _, _ := testStore(t, 0, 0)
	id := Identity{1, 1}
	g := grant(t, s, id)
	if g.Status != "accepted" || g.Grant == "" {
		t.Fatal(g)
	}
	r := snapshot(g, "2026-10-23", 1)
	if got := call(t, s, id, r); got.Rows[0].Status != "accepted" {
		t.Fatal(got)
	}
	if got := call(t, s, id, r); got.Rows[0].Status != "duplicate" {
		t.Fatal(got)
	}
	r.Rows[0].LocalCount = 2
	if got := call(t, s, id, r); got.Status != "invalid" {
		t.Fatal(got)
	}
	r = snapshot(g, "2026-10-23", 3)
	r.Rows = append(r.Rows, Row{Day: "2020-01-01", Revision: 1, Coverage: "complete"})
	if got := call(t, s, id, r); got.Status != "invalid" {
		t.Fatal(got)
	}
	r = snapshot(g, "2026-10-23", 1)
	if got := call(t, s, id, r); got.Rows[0].Status != "duplicate" {
		t.Fatal("batch was not atomic", got)
	}
	off := call(t, s, id, Request{Version: 1, Action: "withdraw", Epoch: g.Epoch, Grant: g.Grant})
	if off.Enabled || off.Epoch <= g.Epoch || off.Grant != "" {
		t.Fatal(off)
	}
	g2 := grant(t, s, id)
	if g2.Epoch <= off.Epoch {
		t.Fatal(g2)
	}
	if got := call(t, s, id, r); got.Status != "revoked" {
		t.Fatal(got)
	}
	call(t, s, id, snapshot(g2, "2026-10-23", 2))
	erased := call(t, s, id, Request{Version: 1, Action: "delete_device", Epoch: g2.Epoch, Grant: g2.Grant})
	if erased.DeletionCutoff != g2.Epoch || !erased.PropagationPending {
		t.Fatal(erased)
	}
	var n int
	if err := s.db.QueryRow("SELECT count(*) FROM daily").Scan(&n); err != nil || n != 0 {
		t.Fatal(n, err)
	}
	if got := grant(t, s, id); got.Status != "busy" {
		t.Fatal("enabled before downstream delete ack", got)
	}
}
func TestIdentityRevocationRetentionAndCapacity(t *testing.T) {
	s, a, now := testStore(t, 1, 1)
	id := Identity{1, 1}
	g := grant(t, s, id)
	if got := grant(t, s, Identity{2, 2}); got.Status != "busy" {
		t.Fatal(got)
	}
	call(t, s, id, snapshot(g, "2026-10-23", 1))
	if got := call(t, s, id, snapshot(g, "2026-10-22", 1)); got.Status != "busy" {
		t.Fatal(got)
	}
	if got := call(t, s, Identity{2, 1}, Request{Version: 1, Action: "status"}); got.UserID != "" {
		t.Fatal("identity leak", got)
	}
	a.Store(false)
	if got := call(t, s, id, snapshot(g, "2026-10-23", 2)); got.Status != "revoked" {
		t.Fatal(got)
	}
	if err := s.Reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	a.Store(true)
	if got := call(t, s, id, snapshot(g, "2026-10-23", 2)); got.Status != "revoked" {
		t.Fatal(got)
	}
	*now = now.AddDate(0, 0, 90)
	if err := s.Purge(context.Background()); err != nil {
		t.Fatal(err)
	}
	var n int
	s.db.QueryRow("SELECT count(*) FROM daily").Scan(&n)
	if n != 0 {
		t.Fatal(n)
	}
}
func TestUserDeletionIsScopedAcrossDevices(t *testing.T) {
	s, _, _ := testStore(t, 0, 0)
	for _, id := range []Identity{{1, 1}, {1, 2}, {2, 3}} {
		g := grant(t, s, id)
		call(t, s, id, snapshot(g, "2026-10-23", 1))
	}
	g := call(t, s, Identity{1, 1}, Request{Version: 1, Action: "status"})
	call(t, s, Identity{1, 1}, Request{Version: 1, Action: "delete_user", Epoch: g.Epoch, Grant: g.Grant})
	var n int
	s.db.QueryRow("SELECT count(*) FROM daily").Scan(&n)
	if n != 1 {
		t.Fatal(n)
	}
}
func TestStrictWire(t *testing.T) {
	for _, input := range []string{`{"version":1,"action":"status","user_id":1}`, `{"version":1,"action":"snapshot","epoch":1,"grant":"00000000-0000-0000-0000-000000000000","rows":[{"day":"2026-10-23","revision":1,"coverage":"complete"}]}`, `{"version":1,"action":"status"} {}`, `{"version":1,"action":"snapshot","epoch":18446744073709551615}`} {
		if _, err := Decode([]byte(input)); err == nil {
			t.Fatal(input)
		}
	}
}

func TestControlCASAndDeleteRetryDoNotAdvancePendingRevision(t *testing.T) {
	s, _, _ := testStore(t, 0, 0)
	id := Identity{1, 1}
	g := grant(t, s, id)
	off := call(t, s, id, Request{Version: 1, Action: "withdraw", Epoch: g.Epoch, Grant: g.Grant})
	if off.Enabled {
		t.Fatal(off)
	}
	deletion := Request{Version: 1, Action: "delete_device", Epoch: g.Epoch, Grant: g.Grant}
	first := call(t, s, id, deletion)
	again := call(t, s, id, deletion)
	if first.ControlRevision != again.ControlRevision || again.Status != "duplicate" {
		t.Fatal(first, again)
	}
	userDelete := deletion
	userDelete.Action = "delete_user"
	first = call(t, s, id, userDelete)
	again = call(t, s, id, userDelete)
	if first.ControlRevision != again.ControlRevision || again.Status != "duplicate" {
		t.Fatal(first, again)
	}
	// A new active grant rejects an old queued account-bound control.
	if _, e := s.db.Exec("UPDATE controls SET ack=revision"); e != nil {
		t.Fatal(e)
	}
	fresh := grant(t, s, id)
	if fresh.Grant == g.Grant {
		t.Fatal(fresh)
	}
	if got := call(t, s, id, deletion); got.Status != "revoked" || got.Epoch != fresh.Epoch {
		t.Fatal(got)
	}
}
