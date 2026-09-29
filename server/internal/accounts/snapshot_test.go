package accounts

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"
)

// watched opens the serving store with a watcher and a second store on the
// same file standing in for flowd admin (another connection, as in
// production).
func watched(t *testing.T) (serve *Store, admin *Store, watcher *Watcher, lost chan Lost, clock *fakeClock) {
	t.Helper()
	serve, clock, dir := openStore(t)
	admin, err := Open(dir, clock.Now)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { admin.Close() })
	lost = make(chan Lost, 8)
	watcher, err = serve.Watch(ctx, func(l Lost) { lost <- l })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { watcher.Close() })
	return serve, admin, watcher, lost, clock
}

func poll(t *testing.T, w *Watcher) bool {
	t.Helper()
	changed, err := w.Poll(ctx)
	if err != nil {
		t.Fatal(err)
	}
	return changed
}

func TestSnapshotReloadsOnDataVersionChange(t *testing.T) {
	_, admin, watcher, lost, _ := watched(t)
	if poll(t, watcher) {
		t.Fatal("nothing changed")
	}
	user, _, _ := admin.EnsureUser(ctx, "apple", "sub", "")
	device, _ := admin.AddDevice(ctx, user.ID, "Mac", deviceKey(1))
	if !poll(t, watcher) {
		t.Fatal("commit by another connection not seen")
	}
	if state, ok := watcher.Snapshot().User(user.ID); !ok || state != UserPending {
		t.Fatal(state, ok)
	}
	if poll(t, watcher) {
		t.Fatal("reloaded without a change")
	}
	_ = admin.SetUserState(ctx, user.ID, UserApproved, AdminActor("oliver"))
	_ = admin.SetDeviceState(ctx, device.ID, DeviceApproved, AdminActor("oliver"))
	poll(t, watcher)
	got, ok := watcher.Snapshot().Device(device.ID)
	if !ok || got.State != DeviceApproved || got.UserID != user.ID || len(got.PublicKey) != 65 || !watcher.Snapshot().Approved(user.ID, device.ID) {
		t.Fatalf("%+v", got)
	}
	select {
	case l := <-lost:
		t.Fatalf("approval reported as lost: %+v", l)
	default:
	}
}

// The callback reports every user and device that stopped being approved.
func TestSnapshotReportsLostApproval(t *testing.T) {
	_, admin, watcher, lost, _ := watched(t)
	var devices []Device
	var users []User
	for i, subject := range []string{"a", "b"} {
		user, _, _ := admin.EnsureUser(ctx, "apple", subject, "")
		_ = admin.SetUserState(ctx, user.ID, UserApproved, AdminActor("oliver"))
		for j := range 2 {
			device, _ := admin.AddDevice(ctx, user.ID, "Mac", deviceKey(byte(1+2*i+j)))
			_ = admin.SetDeviceState(ctx, device.ID, DeviceApproved, AdminActor("oliver"))
			devices = append(devices, device)
		}
		users = append(users, user)
	}
	poll(t, watcher)

	_ = admin.SetDeviceState(ctx, devices[0].ID, DeviceRevoked, AdminActor("oliver"))
	poll(t, watcher)
	if l := <-lost; !slices.Equal(l.Devices, []int64{devices[0].ID}) || len(l.Users) != 0 {
		t.Fatalf("%+v", l)
	}
	if watcher.Snapshot().Approved(users[0].ID, devices[0].ID) || !watcher.Snapshot().Approved(users[0].ID, devices[1].ID) {
		t.Fatal("snapshot state")
	}

	_ = admin.SetUserState(ctx, users[1].ID, UserRevoked, AdminActor("oliver"))
	_ = admin.SetDeviceState(ctx, devices[1].ID, DeviceRevoked, AdminActor("oliver"))
	poll(t, watcher)
	l := <-lost
	if !slices.Equal(l.Users, []int64{users[1].ID}) || !slices.Equal(l.Devices, []int64{devices[1].ID}) {
		t.Fatalf("%+v", l)
	}
	if watcher.Snapshot().Approved(users[1].ID, devices[2].ID) {
		t.Fatal("device of a revoked user must not be approved")
	}
}

// Run polls on each tick of the injected ticker until the context ends.
func TestWatcherRunUsesTicker(t *testing.T) {
	_, admin, watcher, lost, _ := watched(t)
	user, _, _ := admin.EnsureUser(ctx, "apple", "sub", "")
	_ = admin.SetUserState(ctx, user.ID, UserApproved, AdminActor("oliver"))
	poll(t, watcher)
	ticks := make(chan time.Time)
	runCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() { watcher.Run(runCtx, ticks); close(done) }()
	_ = admin.SetUserState(ctx, user.ID, UserRevoked, AdminActor("oliver"))
	select {
	case l := <-lost:
		t.Fatalf("reported before a tick: %+v", l)
	case <-time.After(50 * time.Millisecond):
	}
	ticks <- time.Now()
	select {
	case l := <-lost:
		if !slices.Equal(l.Users, []int64{user.ID}) {
			t.Fatalf("%+v", l)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("tick did not poll")
	}
	cancel()
	<-done
	if PollInterval != 250*time.Millisecond {
		t.Fatal(PollInterval)
	}
}

func TestSnapshotAuthenticate(t *testing.T) {
	serve, admin, watcher, _, clock := watched(t)
	user, _, _ := admin.EnsureUser(ctx, "apple", "sub", "")
	device, _ := admin.AddDevice(ctx, user.ID, "Mac", deviceKey(1))
	_ = admin.SetUserState(ctx, user.ID, UserApproved, AdminActor("oliver"))
	_ = admin.SetDeviceState(ctx, device.ID, DeviceApproved, AdminActor("oliver"))
	token, _, _ := serve.IssueAccess(ctx, device.ID)
	poll(t, watcher)
	principal, err := watcher.Snapshot().Authenticate(token, clock.Now())
	if err != nil || principal.UserID != user.ID || principal.DeviceID != device.ID {
		t.Fatal(principal, err)
	}
	if _, err := watcher.Snapshot().Authenticate("lfa_unknown", clock.Now()); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
	if _, err := watcher.Snapshot().Authenticate(token, clock.Now().Add(AccessLifetime)); !errors.Is(err, ErrTokenExpired) {
		t.Fatal("expired by the server clock", err)
	}
	_ = admin.SetUserState(ctx, user.ID, UserRevoked, AdminActor("oliver"))
	poll(t, watcher)
	if _, err := watcher.Snapshot().Authenticate(token, clock.Now()); !errors.Is(err, ErrRevoked) {
		t.Fatal(err)
	}
	_ = admin.SetUserState(ctx, user.ID, UserApproved, AdminActor("oliver"))
	if _, err := admin.db.Exec(`UPDATE devices SET state = 'pending' WHERE id = ?`, device.ID); err != nil {
		t.Fatal(err)
	}
	poll(t, watcher)
	if _, err := watcher.Snapshot().Authenticate(token, clock.Now()); !errors.Is(err, ErrNotApproved) {
		t.Fatal(err)
	}
	// Revocation clears the access hash but keeps a tombstone, so the
	// device's last token is answered revoked rather than unknown.
	_ = admin.SetDeviceState(ctx, device.ID, DeviceApproved, AdminActor("oliver"))
	_ = admin.SetDeviceState(ctx, device.ID, DeviceRevoked, AdminActor("oliver"))
	poll(t, watcher)
	if _, err := watcher.Snapshot().Authenticate(token, clock.Now()); !errors.Is(err, ErrRevoked) {
		t.Fatal(err)
	}
	if got, _ := admin.Device(ctx, device.ID); got.AccessHash != nil {
		t.Fatal("revocation must clear access_hash")
	}
	// Approved again, the old token is simply unknown: it was never reissued.
	_ = admin.SetDeviceState(ctx, device.ID, DeviceApproved, AdminActor("oliver"))
	poll(t, watcher)
	if _, err := watcher.Snapshot().Authenticate(token, clock.Now()); !errors.Is(err, ErrUnauthorized) {
		t.Fatal(err)
	}
}

// Unsigned refresh reuse revokes the device; its last access token is answered
// revoked.
func TestSnapshotRevokedByRefreshReuse(t *testing.T) {
	serve, admin, watcher, _, clock := watched(t)
	user, _, _ := admin.EnsureUser(ctx, "apple", "sub", "")
	device, _ := admin.AddDevice(ctx, user.ID, "Mac", deviceKey(1))
	_ = admin.SetUserState(ctx, user.ID, UserApproved, AdminActor("oliver"))
	_ = admin.SetDeviceState(ctx, device.ID, DeviceApproved, AdminActor("oliver"))
	refresh, _, _ := serve.IssueRefresh(ctx, device.ID)
	tokens, err := serve.Refresh(ctx, refresh, func(Device) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if _, err := serve.Refresh(ctx, refresh, func(Device) error { return ErrUnauthorized }); !errors.Is(err, ErrRefreshReuse) {
		t.Fatal(err)
	}
	poll(t, watcher)
	if _, err := watcher.Snapshot().Authenticate(tokens.Access, clock.Now()); !errors.Is(err, ErrRevoked) {
		t.Fatal(err)
	}
}
