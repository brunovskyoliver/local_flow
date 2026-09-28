package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"localflow/server/internal/accounts"
)

// fakeKeychain imitates /usr/bin/security for generic passwords.
type fakeKeychain struct{ items map[string]string }

type statusError int

func (e statusError) Error() string { return fmt.Sprintf("exit status %d", int(e)) }
func (e statusError) ExitCode() int { return int(e) }

func (f *fakeKeychain) Run(_ context.Context, stdin []byte, args ...string) ([]byte, error) {
	value := func(name string) string { return args[slices.Index(args, name)+1] }
	key := value("-s") + "|" + value("-a")
	switch args[0] {
	case "add-generic-password":
		if _, ok := f.items[key]; ok {
			return nil, statusError(45)
		}
		f.items[key] = strings.SplitN(string(stdin), "\n", 2)[0]
		return nil, nil
	case "find-generic-password":
		secret, ok := f.items[key]
		if !ok {
			return nil, statusError(44)
		}
		return []byte(secret + "\n"), nil
	}
	return nil, errors.New("unexpected security command")
}

// useKeychain swaps the process keychain runner for a fake one.
func useKeychain(t *testing.T) *fakeKeychain {
	t.Helper()
	fake := &fakeKeychain{items: map[string]string{}}
	previous := keychainRunner
	keychainRunner = fake
	t.Cleanup(func() { keychainRunner = previous })
	return fake
}

func admin(args ...string) (string, error) {
	var out bytes.Buffer
	err := run(context.Background(), append([]string{"admin"}, args...), func(string) string { return "" }, &out)
	return out.String(), err
}

func TestAdminInit(t *testing.T) {
	keychain := useKeychain(t)
	dir := filepath.Join(t.TempDir(), "LocalFlow Server")
	out, err := admin("--data-dir", dir, "init")
	if err != nil || exitCode(err) != 0 {
		t.Fatal(out, err)
	}
	info, err := os.Stat(dir)
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatal("data directory must be 0700", err)
	}
	info, err = os.Stat(filepath.Join(dir, accounts.FileName))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatal("database must exist with 0600", err)
	}
	secret, ok := keychain.items[accounts.ServiceProduction+"|"+dir]
	if !ok {
		t.Fatal("key not stored under the production service and the absolute data directory")
	}
	raw, _ := hex.DecodeString(secret)
	identity, _ := accounts.Keychain{Runner: keychain, Service: accounts.ServiceProduction}.Load(context.Background(), dir)
	if !strings.Contains(out, identity.Fingerprint()) || strings.Contains(out, secret) || len(raw) != 32 {
		t.Fatalf("init output %q", out)
	}

	// A second init is refused and changes nothing.
	out, err = admin("--data-dir", dir, "init")
	if exitCode(err) != 1 || !strings.Contains(err.Error(), "already exists") || keychain.items[accounts.ServiceProduction+"|"+dir] != secret {
		t.Fatal(out, err)
	}
}

func TestAdminIdentity(t *testing.T) {
	keychain := useKeychain(t)
	dir := t.TempDir()
	if _, err := admin("--data-dir", dir, "identity"); exitCode(err) != 1 || !strings.Contains(err.Error(), "admin init") {
		t.Fatal("identity without a key", err)
	}
	if _, err := admin("--data-dir", dir, "init"); err != nil {
		t.Fatal(err)
	}
	out, err := admin("--data-dir", dir, "identity")
	if err != nil {
		t.Fatal(err)
	}
	identity, _ := accounts.Keychain{Runner: keychain, Service: accounts.ServiceProduction}.Load(context.Background(), dir)
	want := "fingerprint " + identity.Fingerprint() + "\npublic key " + base64.RawURLEncoding.EncodeToString(identity.PublicKey()) + "\n"
	if out != want {
		t.Fatalf("%q != %q", out, want)
	}
	if strings.Contains(out, keychain.items[accounts.ServiceProduction+"|"+dir]) {
		t.Fatal("private key printed")
	}
}

func TestAdminDevService(t *testing.T) {
	keychain := useKeychain(t)
	dir := t.TempDir()
	if _, err := admin("--data-dir", dir, "--dev", "init"); err != nil {
		t.Fatal(err)
	}
	if _, ok := keychain.items[accounts.ServiceDevelopment+"|"+dir]; !ok {
		t.Fatal("--dev must use the development service")
	}
	if _, err := admin("--data-dir", dir, "identity"); exitCode(err) != 1 {
		t.Fatal("production service must not see the dev key", err)
	}
}

func TestAdminUsageErrors(t *testing.T) {
	useKeychain(t)
	dir := t.TempDir()
	for _, args := range [][]string{
		{},
		{"init"},
		{"--data-dir", dir},
		{"--data-dir", dir, "launch"},
		{"--data-dir", dir, "init", "extra"},
		{"--data-dir", dir, "identity", "extra"},
		{"--data-dir", "", "init"},
		{"--bogus", "--data-dir", dir, "init"},
	} {
		if _, err := admin(args...); exitCode(err) != exitUsage {
			t.Errorf("%q: %v", args, err)
		}
	}
}

func TestExitCodes(t *testing.T) {
	if exitCode(nil) != 0 || exitCode(errors.New("x")) != 1 {
		t.Fatal("defaults")
	}
	for err, want := range map[error]int{
		adminError(accounts.ErrNotFound):                                               exitNotFound,
		adminError(&accounts.TransitionError{Kind: "user", From: "a", To: "b"}):        exitTransition,
		adminError(fmt.Errorf("wrapped: %w", accounts.ErrNotFound)):                    exitNotFound,
		adminError(errors.New("anything else")):                                        1,
		&exitError{code: exitUsage, err: errors.New("usage")}:                          exitUsage,
		fmt.Errorf("outer: %w", &exitError{code: exitTransition, err: errors.New("")}): exitTransition,
	} {
		if got := exitCode(err); got != want {
			t.Errorf("%v: %d, want %d", err, got, want)
		}
	}
}

// adminEnv fixes the admin clock, time zone and Unix user for a test.
func adminEnv(t *testing.T, now time.Time, zone *time.Location, unixUser string) {
	t.Helper()
	previousNow, previousZone, previousUser := adminNow, adminLocation, adminUnixUser
	adminNow = func() time.Time { return now }
	adminLocation = zone
	adminUnixUser = func() string { return unixUser }
	t.Cleanup(func() { adminNow, adminLocation, adminUnixUser = previousNow, previousZone, previousUser })
}

// seeded is a data directory with the accounts of contracts/flowd-cli.md's
// list example, created through the store with a settable clock.
type seeded struct {
	dir                    string
	zone                   *time.Location
	oliver, pending        accounts.User
	macbook, studio        accounts.Device
	secrets                []string
	pendingUserDevice      accounts.Device
	pendingUserDeviceSince time.Time
}

func seedAccounts(t *testing.T) *seeded {
	t.Helper()
	ctx := context.Background()
	zone := time.FixedZone("CEST", 2*60*60)
	at := time.Date(2026, 10, 2, 18, 4, 0, 0, zone)
	clock := func() time.Time { return at }
	s := &seeded{dir: t.TempDir(), zone: zone}
	store, err := accounts.Open(s.dir, func() time.Time { return clock() })
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	key := func(n byte) []byte {
		k := bytes.Repeat([]byte{n}, 65)
		k[0] = 0x04
		return k
	}
	admin := accounts.AdminActor("seed")
	s.oliver, _, _ = store.EnsureUser(ctx, "apple", "001234.abc", "oliver@example.com")
	s.macbook, _ = store.AddDevice(ctx, s.oliver.ID, "MacBook Pro", key(1))
	_ = store.SetUserState(ctx, s.oliver.ID, accounts.UserApproved, admin)
	_ = store.SetDeviceState(ctx, s.macbook.ID, accounts.DeviceApproved, admin)
	refresh, _, _ := store.IssueRefresh(ctx, s.macbook.ID)
	access, _, _ := store.IssueAccess(ctx, s.macbook.ID)
	at = time.Date(2026, 10, 3, 8, 55, 0, 0, zone)
	s.studio, _ = store.AddDevice(ctx, s.oliver.ID, "Mac Studio", key(2))
	at = time.Date(2026, 10, 3, 9, 12, 0, 0, zone)
	_, _ = store.TouchDevice(ctx, s.macbook.ID)
	at = time.Date(2026, 10, 3, 10, 0, 0, 0, zone)
	s.pending, _, _ = store.EnsureUser(ctx, "google", "1098765", "")
	s.pendingUserDevice, _ = store.AddDevice(ctx, s.pending.ID, "iMac", key(3))
	device, _ := store.Device(ctx, s.macbook.ID)
	s.secrets = []string{refresh, access, "001234.abc", "1098765",
		hex.EncodeToString(device.RefreshHash), hex.EncodeToString(device.AccessHash), hex.EncodeToString(device.PublicKey),
		base64.RawURLEncoding.EncodeToString(device.PublicKey), base64.StdEncoding.EncodeToString(device.PublicKey),
		base64.RawURLEncoding.EncodeToString(device.RefreshHash), base64.StdEncoding.EncodeToString(device.AccessHash)}
	return s
}

func TestAdminListFormat(t *testing.T) {
	s := seedAccounts(t)
	adminEnv(t, time.Now(), s.zone, "oliver")
	out, err := admin("--data-dir", s.dir, "list")
	if err != nil {
		t.Fatal(err)
	}
	want := "" +
		"user 1  apple   oliver@example.com  approved  created 2026-10-02 18:04\n" +
		"  device 1  MacBook Pro  approved  enrolled 2026-10-02 18:04  last seen 2026-10-03 09:12\n" +
		"  device 2  Mac Studio   pending   enrolled 2026-10-03 08:55  last seen never\n" +
		"user 2  google  -                   pending   created 2026-10-03 10:00\n" +
		"  device 3  iMac         pending   enrolled 2026-10-03 10:00  last seen never\n"
	if out != want {
		t.Fatalf("list:\n%s\nwant:\n%s", out, want)
	}
	// The contract example, one user: its lines match the contract exactly.
	out, err = admin("--data-dir", s.dir, "list", "--state", "approved")
	if err != nil {
		t.Fatal(err)
	}
	contract := "" +
		"user 1  apple  oliver@example.com  approved  created 2026-10-02 18:04\n" +
		"  device 1  MacBook Pro  approved  enrolled 2026-10-02 18:04  last seen 2026-10-03 09:12\n" +
		"  device 2  Mac Studio   pending   enrolled 2026-10-03 08:55  last seen never\n"
	if out != contract {
		t.Fatalf("list --state approved:\n%s\nwant:\n%s", out, contract)
	}
	// Times are local time of the admin's zone.
	adminEnv(t, time.Now(), time.UTC, "oliver")
	out, _ = admin("--data-dir", s.dir, "list", "--state", "approved")
	if !strings.Contains(out, "created 2026-10-02 16:04") {
		t.Fatal(out)
	}
}

// --state S shows users in state S and users with a device in state S.
func TestAdminListState(t *testing.T) {
	s := seedAccounts(t)
	adminEnv(t, time.Now(), s.zone, "oliver")
	for state, users := range map[string]string{
		"pending":  "user 1 user 2",
		"approved": "user 1",
		"rejected": "",
		"revoked":  "",
	} {
		out, err := admin("--data-dir", s.dir, "list", "--state", state)
		if err != nil {
			t.Fatal(state, err)
		}
		var got []string
		for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
			if fields := strings.Fields(line); len(fields) > 1 && fields[0] == "user" {
				got = append(got, "user "+fields[1])
			}
		}
		if strings.Join(got, " ") != users {
			t.Errorf("--state %s: %q", state, out)
		}
	}
	for _, args := range [][]string{{"list", "--state", "bogus"}, {"list", "extra"}, {"list", "--state"}} {
		if _, err := admin(append([]string{"--data-dir", s.dir}, args...)...); exitCode(err) != exitUsage {
			t.Errorf("%q: %v", args, err)
		}
	}
	empty := t.TempDir()
	if out, err := admin("--data-dir", empty, "list"); err != nil || out != "" {
		t.Fatal(out, err)
	}
}

func TestAdminTransitions(t *testing.T) {
	s := seedAccounts(t)
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, s.zone)
	adminEnv(t, now, s.zone, "oliver")
	ctx := context.Background()
	id := func(n int64) string { return strconv.FormatInt(n, 10) }
	steps := []struct {
		args []string
		code int
		out  string
	}{
		// Approving a device of a pending user does not approve the user.
		{[]string{"approve", "device", id(s.pendingUserDevice.ID)}, 0, "device 3 approved\n"},
		{[]string{"approve", "device", id(s.pendingUserDevice.ID)}, exitTransition, ""},
		{[]string{"approve", "user", id(s.pending.ID)}, 0, "user 2 approved\n"},
		{[]string{"approve", "user", id(s.pending.ID)}, exitTransition, ""},
		{[]string{"reject", "user", id(s.oliver.ID)}, exitTransition, ""},
		{[]string{"revoke", "user", id(s.oliver.ID)}, 0, "user 1 revoked\n"},
		{[]string{"revoke", "user", id(s.oliver.ID)}, exitTransition, ""},
		{[]string{"approve", "user", id(s.oliver.ID)}, 0, "user 1 approved\n"},
		{[]string{"revoke", "device", id(s.studio.ID)}, 0, "device 2 revoked\n"},
		{[]string{"approve", "device", id(s.studio.ID)}, 0, "device 2 approved\n"},
		{[]string{"revoke", "device", id(s.macbook.ID)}, 0, "device 1 revoked\n"},
		{[]string{"approve", "user", "999"}, exitNotFound, ""},
		{[]string{"revoke", "device", "999"}, exitNotFound, ""},
		{[]string{"reject", "device", id(s.studio.ID)}, exitUsage, ""},
		{[]string{"approve", "group", "1"}, exitUsage, ""},
		{[]string{"approve", "user"}, exitUsage, ""},
		{[]string{"approve", "user", "x"}, exitUsage, ""},
		{[]string{"approve", "user", "0"}, exitUsage, ""},
		{[]string{"approve", "user", "-1"}, exitUsage, ""},
		{[]string{"approve", "user", "1", "2"}, exitUsage, ""},
		{[]string{"approve"}, exitUsage, ""},
	}
	for _, step := range steps {
		out, err := admin(append([]string{"--data-dir", s.dir}, step.args...)...)
		if exitCode(err) != step.code || (step.code == 0 && out != step.out) {
			t.Errorf("%q: exit %d (%v), output %q", step.args, exitCode(err), err, out)
		}
	}
	store, err := accounts.Open(s.dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	pendingDevice, _ := store.Device(ctx, s.pendingUserDevice.ID)
	macbook, _ := store.Device(ctx, s.macbook.ID)
	if pendingDevice.State != accounts.DeviceApproved || macbook.State != accounts.DeviceRevoked || macbook.RefreshHash != nil || macbook.AccessHash != nil {
		t.Fatalf("%+v %+v", pendingDevice, macbook)
	}
	// One audit row per successful mutation, actor admin:<unix user>, at the
	// admin clock.
	entries, _ := store.AuditLog(ctx, 100)
	var mine []accounts.AuditEntry
	for _, e := range entries {
		if e.Actor == "admin:oliver" {
			mine = append(mine, e)
		}
	}
	if len(mine) != 7 || mine[0].Action != "revoke" || mine[0].Target != "device:1" || mine[0].Outcome != "ok" || !mine[0].At.Equal(now) {
		t.Fatalf("%+v", mine)
	}
}

// Approving the device of a pending user leaves the user pending.
func TestAdminDeviceApprovalKeepsUserPending(t *testing.T) {
	s := seedAccounts(t)
	adminEnv(t, time.Now(), s.zone, "oliver")
	if _, err := admin("--data-dir", s.dir, "approve", "device", strconv.FormatInt(s.pendingUserDevice.ID, 10)); err != nil {
		t.Fatal(err)
	}
	out, _ := admin("--data-dir", s.dir, "list", "--state", "pending")
	var user, device []string
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		switch {
		case len(fields) > 4 && fields[0] == "user" && fields[1] == "2":
			user = fields
		case len(fields) > 3 && fields[0] == "device" && fields[1] == "3":
			device = fields
		}
	}
	if user == nil || user[4] != "pending" || device == nil || device[3] != "approved" {
		t.Fatal(out)
	}
}

func TestAdminAudit(t *testing.T) {
	s := seedAccounts(t)
	now := time.Date(2026, 10, 5, 7, 30, 0, 0, s.zone)
	adminEnv(t, now, s.zone, "oliver")
	store, err := accounts.Open(s.dir, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	for i := range 60 {
		_ = store.Audit(context.Background(), accounts.AuditEntry{Actor: accounts.SystemActor, Action: "rate_limited", Outcome: "busy"})
		_ = i
	}
	_ = store.Audit(context.Background(), accounts.AuditEntry{Actor: accounts.UserActor(1), Action: "sign_in", Target: accounts.UserTarget(1), Outcome: "ok"})
	store.Close()
	out, err := admin("--data-dir", s.dir, "audit")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	if len(lines) != 50 || lines[0] != "2026-10-05 07:30  user:1  sign_in  user:1  ok" ||
		lines[1] != "2026-10-05 07:30  system  rate_limited  -  busy" {
		t.Fatalf("%d lines:\n%s", len(lines), out)
	}
	out, _ = admin("--data-dir", s.dir, "audit", "--limit", "2")
	if strings.Count(out, "\n") != 2 {
		t.Fatal(out)
	}
	out, _ = admin("--data-dir", s.dir, "audit", "--limit", "10000")
	if strings.Count(out, "\n") != 61+2 { // plus the seed's two admin rows
		t.Fatal(strings.Count(out, "\n"))
	}
	for _, args := range [][]string{{"audit", "--limit", "0"}, {"audit", "--limit", "-1"}, {"audit", "--limit", "x"}, {"audit", "--limit", "10001"}, {"audit", "extra"}} {
		if _, err := admin(append([]string{"--data-dir", s.dir}, args...)...); exitCode(err) != exitUsage {
			t.Errorf("%q: %v", args, err)
		}
	}
}

// No admin command prints tokens, hashes, keys or provider subjects.
func TestAdminPrintsNoSecrets(t *testing.T) {
	s := seedAccounts(t)
	adminEnv(t, time.Now(), s.zone, "oliver")
	var all strings.Builder
	for _, args := range [][]string{
		{"list"}, {"list", "--state", "approved"}, {"audit"},
		{"approve", "user", "2"}, {"revoke", "device", "1"}, {"reject", "user", "2"}, {"audit", "--limit", "100"}, {"list"},
	} {
		out, _ := admin(append([]string{"--data-dir", s.dir}, args...)...)
		all.WriteString(out)
	}
	for _, secret := range s.secrets {
		if secret != "" && strings.Contains(all.String(), secret) {
			t.Fatalf("admin output contains %q", secret)
		}
	}
	for _, prefix := range []string{"lfr_", "lfa_"} {
		if strings.Contains(all.String(), prefix) {
			t.Fatal("token prefix printed")
		}
	}
}

func TestAdminUnixUser(t *testing.T) {
	for in, want := range map[string]string{
		"oliver":                "oliver",
		"first.last":            "first.last",
		"DOMAIN\\name":          "DOMAIN_name",
		"":                      "",
		strings.Repeat("a", 70): strings.Repeat("a", 64),
	} {
		if got := sanitizeUnixUser(in); got != want {
			t.Errorf("%q: %q", in, got)
		}
	}
	if user := currentUnixUser(); !regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`).MatchString(user) {
		t.Fatal(user)
	}
}
