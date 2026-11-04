package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
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
	s.macbook, _ = store.AddDevice(ctx, s.oliver.ID, "MacBook Pro", key(1), "")
	_ = store.SetUserState(ctx, s.oliver.ID, accounts.UserApproved, admin)
	_ = store.SetDeviceState(ctx, s.macbook.ID, accounts.DeviceApproved, admin)
	refresh, _, _ := store.IssueRefresh(ctx, s.macbook.ID)
	access, _, _ := store.IssueAccess(ctx, s.macbook.ID)
	at = time.Date(2026, 10, 3, 8, 55, 0, 0, zone)
	s.studio, _ = store.AddDevice(ctx, s.oliver.ID, "Mac Studio", key(2), "")
	at = time.Date(2026, 10, 3, 9, 12, 0, 0, zone)
	_, _ = store.TouchDevice(ctx, s.macbook.ID)
	at = time.Date(2026, 10, 3, 10, 0, 0, 0, zone)
	s.pending, _, _ = store.EnsureUser(ctx, "google", "1098765", "")
	s.pendingUserDevice, _ = store.AddDevice(ctx, s.pending.ID, "iMac", key(3), "")
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
// A token user lists like any other, with its label and provider.
func TestAdminListShowsTokenUser(t *testing.T) {
	s := seedAccounts(t)
	adminEnv(t, time.Now(), s.zone, "oliver")
	store, err := accounts.Open(s.dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	value, _, err := store.CreatePairingToken(context.Background(), make([]byte, 32), "Anna", 0, time.Hour, accounts.AdminActor("oliver"))
	if err != nil {
		t.Fatal(err)
	}
	key := bytes.Repeat([]byte{9}, 65)
	key[0] = 0x04
	if _, err := store.RedeemPairingToken(context.Background(), value, "Anna's Phone", key, ""); err != nil {
		t.Fatal(err)
	}
	out, err := admin("--data-dir", s.dir, "list", "--state", "approved")
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`user \d+\s+token\s+Anna\s+approved`).MatchString(out) || !strings.Contains(out, "Anna's Phone") {
		t.Fatal(out)
	}
	if strings.Contains(out, value) || strings.Contains(out, "token:") {
		t.Fatalf("secrets or subjects printed:\n%s", out)
	}
}

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
		{"list"}, {"list", "--state", "approved"}, {"audit"}, {"list", "--json"}, {"audit", "--json"},
		{"approve", "user", "2"}, {"revoke", "device", "1"}, {"reject", "user", "2"}, {"audit", "--limit", "100"}, {"list"},
		{"user", "create", "--name", "Ana", "--json"}, {"rename", "device", "2", "--name", "Studio"}, {"list", "--json"},
	} {
		out, _ := admin(append([]string{"--data-dir", s.dir}, args...)...)
		all.WriteString(out)
	}
	for _, secret := range s.secrets {
		if secret != "" && strings.Contains(all.String(), secret) {
			t.Fatalf("admin output contains %q", secret)
		}
	}
	for _, prefix := range []string{"lfr_", "lfa_", "named:"} {
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

// Create prints the value once; list and the database never hold it; revoke
// and the exit codes follow flowd admin (contracts/pairing.md).
func TestAdminToken(t *testing.T) {
	useKeychain(t)
	dir := t.TempDir()
	if _, err := admin("--data-dir", dir, "--dev", "init"); err != nil {
		t.Fatal(err)
	}
	out, err := admin("--data-dir", dir, "--dev", "token", "create", "--label", "Anna", "--ttl", "7d",
		"--address", "https://mini.example.com:8443", "--json")
	if err != nil {
		t.Fatal(out, err)
	}
	var created struct {
		ID        int64  `json:"id"`
		Label     string `json:"label"`
		ExpiresAt string `json:"expires_at"`
		Token     string `json:"token"`
		Link      string `json:"link"`
	}
	if err := json.Unmarshal([]byte(out), &created); err != nil {
		t.Fatal(out, err)
	}
	wantLink := "localflow-dev://pair?address=https%3A%2F%2Fmini.example.com%3A8443#token=" + created.Token
	if created.ID != 1 || created.Label != "Anna" || !strings.HasPrefix(created.Token, "lfp_") || created.Link != wantLink {
		t.Fatalf("%+v", created)
	}
	expires, err := time.Parse(time.RFC3339, created.ExpiresAt)
	if err != nil || time.Until(expires) < 6*24*time.Hour {
		t.Fatal(created.ExpiresAt, err)
	}

	// The token names this server's key.
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(created.Token, "lfp_"))
	identity, _ := accounts.Keychain{Runner: keychainRunner, Service: accounts.ServiceDevelopment}.Load(context.Background(), dir)
	if err != nil || !bytes.Equal(raw[:32], identity.PublicKey()) {
		t.Fatal("token does not carry the server key", err)
	}

	for _, args := range [][]string{{"token", "list"}, {"token", "list", "--json"}, {"audit"}} {
		out, err := admin(append([]string{"--data-dir", dir, "--dev"}, args...)...)
		if err != nil || strings.Contains(out, "lfp_") || strings.Contains(out, "hash") {
			t.Fatal(args, out, err)
		}
		if !strings.Contains(out, "live") && args[len(args)-1] != "audit" {
			t.Fatal(args, out)
		}
	}
	files, _ := filepath.Glob(filepath.Join(dir, "*"))
	for _, file := range files {
		if data, err := os.ReadFile(file); err == nil && bytes.Contains(data, []byte(created.Token)) {
			t.Fatalf("%s holds the token", file)
		}
	}

	out, err = admin("--data-dir", dir, "--dev", "token", "revoke", "1")
	if err != nil || out != "token 1 revoked\n" {
		t.Fatal(out, err)
	}
	if _, err = admin("--data-dir", dir, "--dev", "token", "revoke", "1"); exitCode(err) != exitTransition {
		t.Fatal(err)
	}
	if _, err = admin("--data-dir", dir, "--dev", "token", "revoke", "99"); exitCode(err) != exitNotFound {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"token"}, {"token", "rename"}, {"token", "create"}, {"token", "revoke", "x"},
		{"token", "create", "--label", "A", "--ttl", "2h"},
		{"token", "create", "--label", "A", "--address", "https://a.example/path"},
		{"token", "create", "--label", "A", "--address", "ftp://a.example"},
	} {
		if _, err := admin(append([]string{"--data-dir", dir, "--dev"}, args...)...); exitCode(err) != exitUsage {
			t.Fatal(args, err)
		}
	}
	if _, err = admin("--data-dir", dir, "--dev", "token", "create", "--label", "A", "--user", "99"); exitCode(err) != exitNotFound {
		t.Fatal(err)
	}
}

type lockedKeychain struct{}

func (lockedKeychain) Run(context.Context, []byte, ...string) ([]byte, error) {
	return nil, statusError(36)
}

// Create without the key fails clearly; list and revoke need no key.
func TestAdminTokenWithoutTheKey(t *testing.T) {
	useKeychain(t)
	dir := t.TempDir()
	if _, err := admin("--data-dir", dir, "token", "create", "--label", "A"); err == nil || !strings.Contains(err.Error(), "admin init") {
		t.Fatal(err)
	}
	if out, err := admin("--data-dir", dir, "token", "list", "--json"); err != nil || strings.TrimSpace(out) != "[]" {
		t.Fatal(out, err)
	}
	// A locked Keychain, as over SSH.
	previous := keychainRunner
	keychainRunner = lockedKeychain{}
	defer func() { keychainRunner = previous }()
	if _, err := admin("--data-dir", dir, "token", "create", "--label", "A"); err == nil || !strings.Contains(err.Error(), "unlock the login Keychain") {
		t.Fatal(err)
	}
	if _, err := admin("--data-dir", dir, "token", "list"); err != nil {
		t.Fatal(err)
	}
}

// The default output has the id, the value and the link only when asked.
func TestAdminTokenText(t *testing.T) {
	useKeychain(t)
	dir := t.TempDir()
	if _, err := admin("--data-dir", dir, "init"); err != nil {
		t.Fatal(err)
	}
	out, err := admin("--data-dir", dir, "token", "create", "--label", "Anna")
	if err != nil {
		t.Fatal(err)
	}
	if lines := strings.Split(strings.TrimSpace(out), "\n"); len(lines) != 2 || !strings.HasPrefix(lines[1], "lfp_") {
		t.Fatal(out)
	}
	out, err = admin("--data-dir", dir, "token", "create", "--label", "Ben", "--address", "https://m.example")
	if err != nil || !strings.Contains(out, "localflow://pair?address=https%3A%2F%2Fm.example#token=lfp_") {
		t.Fatal(out, err)
	}
}

func TestTokenLinkCarriesEveryAddress(t *testing.T) {
	a := &adminContext{}
	got := a.pairingLink([]string{"http://100.64.0.1:8090", "https://flow.example.com"}, "lfp_x")
	want := "localflow://pair?address=http%3A%2F%2F100.64.0.1%3A8090&address=https%3A%2F%2Fflow.example.com#token=lfp_x"
	if got != want {
		t.Fatalf("got %s", got)
	}
}

// setKinds stores device kinds in a seeded data directory: kind is shown by
// list --json and must not change the text list.
func (s *seeded) setKinds(t *testing.T, kinds map[int64]accounts.DeviceKind) {
	t.Helper()
	store, err := accounts.Open(s.dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	for id, kind := range kinds {
		if err := store.FillDeviceKind(context.Background(), id, kind); err != nil {
			t.Fatal(err)
		}
	}
}

// Golden: the text list is byte for byte what it was before list --json and
// device kinds, so LocalFlow Server's text parser keeps working.
func TestAdminListTextGolden(t *testing.T) {
	s := seedAccounts(t)
	s.setKinds(t, map[int64]accounts.DeviceKind{s.macbook.ID: accounts.KindMac, s.pendingUserDevice.ID: accounts.KindIPhone})
	adminEnv(t, time.Now(), s.zone, "oliver")
	want, err := os.ReadFile(filepath.Join("testdata", "admin-list.golden"))
	if err != nil {
		t.Fatal(err)
	}
	out, err := admin("--data-dir", s.dir, "list")
	if err != nil || out != string(want) {
		t.Fatalf("list:\n%s\nwant:\n%s\n%v", out, want, err)
	}
}

// jsonEqual compares two JSON texts as values.
func jsonEqual(t *testing.T, got, want string) {
	t.Helper()
	var g, w any
	if err := json.Unmarshal([]byte(got), &g); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, got)
	}
	if err := json.Unmarshal([]byte(want), &w); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(g, w) {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestAdminListJSON(t *testing.T) {
	s := seedAccounts(t)
	s.setKinds(t, map[int64]accounts.DeviceKind{s.macbook.ID: accounts.KindMac})
	adminEnv(t, time.Now(), s.zone, "oliver")
	out, err := admin("--data-dir", s.dir, "list", "--json")
	if err != nil || !strings.HasSuffix(out, "}\n") || strings.Count(out, "\n") != 1 {
		t.Fatalf("%q %v", out, err)
	}
	jsonEqual(t, out, `{
	  "schema_version": 1,
	  "users": [
	    {"id": 1, "provider": "apple", "display": "oliver@example.com", "state": "approved",
	     "created_at": "2026-10-02T16:04:00Z", "changed_at": "2026-10-02T16:04:00Z",
	     "devices": [
	       {"id": 1, "name": "MacBook Pro", "kind": "mac", "state": "approved", "enrolled_at": "2026-10-02T16:04:00Z",
	        "last_seen_at": "2026-10-03T07:12:00Z", "changed_at": "2026-10-02T16:04:00Z", "invited_by": null},
	       {"id": 2, "name": "Mac Studio", "kind": null, "state": "pending", "enrolled_at": "2026-10-03T06:55:00Z",
	        "last_seen_at": null, "changed_at": "2026-10-03T06:55:00Z", "invited_by": null}
	     ]},
	    {"id": 2, "provider": "google", "display": null, "state": "pending",
	     "created_at": "2026-10-03T08:00:00Z", "changed_at": "2026-10-03T08:00:00Z",
	     "devices": [
	       {"id": 3, "name": "iMac", "kind": null, "state": "pending", "enrolled_at": "2026-10-03T08:00:00Z",
	        "last_seen_at": null, "changed_at": "2026-10-03T08:00:00Z", "invited_by": null}
	     ]}
	  ],
	  "truncated": false
	}`)
	// --state filters as the text form does.
	out, err = admin("--data-dir", s.dir, "list", "--state", "approved", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var listed adminListJSON
	if err := json.Unmarshal([]byte(out), &listed); err != nil || len(listed.Users) != 1 || len(listed.Users[0].Devices) != 2 {
		t.Fatalf("%s %v", out, err)
	}
	out, err = admin("--data-dir", s.dir, "list", "--state", "rejected", "--json")
	if err != nil {
		t.Fatal(err)
	}
	jsonEqual(t, out, `{"schema_version": 1, "users": [], "truncated": false}`)
	if _, err := admin("--data-dir", s.dir, "list", "--json", "extra"); exitCode(err) != exitUsage {
		t.Fatal(err)
	}
}

// A device that redeemed an invite lists the inviting device in invited_by;
// every other device has null.
func TestAdminListJSONInvitedBy(t *testing.T) {
	s := seedAccounts(t)
	store, err := accounts.Open(s.dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	value, _, err := store.CreateInvite(context.Background(), make([]byte, 32), s.macbook.ID)
	if err != nil {
		t.Fatal(err)
	}
	key := bytes.Repeat([]byte{9}, 65)
	key[0] = 0x04
	phone, err := store.Redeem(context.Background(), value, "iPhone", key, accounts.KindIPhone, bytes.Repeat([]byte{1}, 32))
	store.Close()
	if err != nil {
		t.Fatal(err)
	}
	adminEnv(t, time.Now(), s.zone, "oliver")
	out, err := admin("--data-dir", s.dir, "list", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var listed adminListJSON
	if err := json.Unmarshal([]byte(out), &listed); err != nil {
		t.Fatal(err)
	}
	invited := map[int64]*int64{}
	for _, u := range listed.Users {
		for _, d := range u.Devices {
			invited[d.ID] = d.InvitedBy
		}
	}
	if by := invited[phone.DeviceID]; by == nil || *by != s.macbook.ID {
		t.Fatalf("invited_by %v: %s", by, out)
	}
	if invited[s.macbook.ID] != nil || invited[s.studio.ID] != nil {
		t.Fatal(out)
	}
}

// list --json stops at 500 users or 500 devices and says so; only the last
// listed user can have devices missing.
func TestAdminListJSONCaps(t *testing.T) {
	at := time.Unix(1_790_000_000, 0)
	users := func(n int) []accounts.User {
		out := make([]accounts.User, n)
		for i := range out {
			out[i] = accounts.User{ID: int64(i + 1), Provider: "token", State: accounts.UserApproved, CreatedAt: at, ChangedAt: at}
		}
		return out
	}
	devicesOf := func(counts map[int64]int) map[int64][]accounts.Device {
		out := map[int64][]accounts.Device{}
		id := int64(0)
		for user := int64(1); user <= int64(len(counts)); user++ {
			for range counts[user] {
				id++
				out[user] = append(out[user], accounts.Device{ID: id, UserID: user, Name: "d", State: accounts.DeviceApproved, EnrolledAt: at, ChangedAt: at})
			}
		}
		return out
	}
	total := func(l adminListJSON) (n int) {
		for _, u := range l.Users {
			n += len(u.Devices)
		}
		return n
	}
	if l := listJSON(users(500), nil, nil, ""); len(l.Users) != 500 || l.Truncated {
		t.Fatal(len(l.Users), l.Truncated)
	}
	if l := listJSON(users(501), nil, nil, ""); len(l.Users) != 500 || !l.Truncated || l.Users[499].ID != 500 {
		t.Fatal(len(l.Users), l.Truncated)
	}
	if l := listJSON(users(2), devicesOf(map[int64]int{1: 250, 2: 250}), nil, ""); total(l) != 500 || l.Truncated {
		t.Fatal(total(l), l.Truncated)
	}
	l := listJSON(users(3), devicesOf(map[int64]int{1: 499, 2: 3, 3: 1}), nil, "")
	if len(l.Users) != 2 || total(l) != 500 || len(l.Users[1].Devices) != 1 || !l.Truncated {
		t.Fatal(len(l.Users), total(l), l.Truncated)
	}
	// Cut exactly at a user boundary: a later user with devices is cut, one without isn't missing anything.
	l = listJSON(users(3), devicesOf(map[int64]int{1: 500, 2: 0, 3: 1}), nil, "")
	if len(l.Users) != 2 || total(l) != 500 || !l.Truncated {
		t.Fatal(len(l.Users), total(l), l.Truncated)
	}
}

func TestAdminAuditJSON(t *testing.T) {
	s := seedAccounts(t)
	now := time.Date(2026, 10, 5, 7, 30, 15, 0, s.zone)
	adminEnv(t, now, s.zone, "oliver")
	store, err := accounts.Open(s.dir, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	_ = store.Audit(context.Background(), accounts.AuditEntry{Actor: accounts.SystemActor, Action: "rate_limited", Outcome: "busy"})
	_ = store.Audit(context.Background(), accounts.AuditEntry{Actor: accounts.UserActor(1), Action: "sign_in", Target: accounts.UserTarget(1), Outcome: "ok"})
	store.Close()
	out, err := admin("--data-dir", s.dir, "audit", "--limit", "2", "--json")
	if err != nil {
		t.Fatal(err)
	}
	jsonEqual(t, out, `[
	  {"at": "2026-10-05T05:30:15Z", "actor": "user:1", "action": "sign_in", "target": "user:1", "outcome": "ok"},
	  {"at": "2026-10-05T05:30:15Z", "actor": "system", "action": "rate_limited", "target": null, "outcome": "busy"}
	]`)
	empty := t.TempDir()
	if out, err := admin("--data-dir", empty, "audit", "--json"); err != nil || out != "[]\n" {
		t.Fatalf("%q %v", out, err)
	}
	if _, err := admin("--data-dir", s.dir, "audit", "--limit", "0", "--json"); exitCode(err) != exitUsage {
		t.Fatal(err)
	}
}

func TestAdminUserCreate(t *testing.T) {
	s := seedAccounts(t)
	adminEnv(t, time.Now(), s.zone, "oliver")
	out, err := admin("--data-dir", s.dir, "user", "create", "--name", "Ana")
	if err != nil || out != "user 3 approved\n" {
		t.Fatalf("%q %v", out, err)
	}
	out, err = admin("--data-dir", s.dir, "user", "create", "--name", "Ben", "--json")
	if err != nil {
		t.Fatal(err)
	}
	jsonEqual(t, out, `{"id": 4, "display": "Ben", "state": "approved"}`)
	listed, _ := admin("--data-dir", s.dir, "list", "--json")
	var list adminListJSON
	if err := json.Unmarshal([]byte(listed), &list); err != nil || len(list.Users) != 4 || list.Users[2].Provider != "token" ||
		*list.Users[2].Display != "Ana" || list.Users[2].State != "approved" || len(list.Users[2].Devices) != 0 {
		t.Fatalf("%s %v", listed, err)
	}
	if strings.Contains(listed, "named:") {
		t.Fatal("subject printed")
	}
	audit, _ := admin("--data-dir", s.dir, "audit", "--limit", "2")
	if !strings.Contains(audit, "admin:oliver  user_create  user:4  ok") || !strings.Contains(audit, "admin:oliver  user_create  user:3  ok") {
		t.Fatal(audit)
	}
	for _, args := range [][]string{
		{"user"}, {"user", "delete"}, {"user", "create"}, {"user", "create", "--name", ""},
		{"user", "create", "--name", strings.Repeat("n", 321)}, {"user", "create", "--name", "A\x00na"},
		{"user", "create", "--name", "Ana", "extra"}, {"user", "create", "--bogus"},
	} {
		if _, err := admin(append([]string{"--data-dir", s.dir}, args...)...); exitCode(err) != exitUsage {
			t.Errorf("%q: %v", args, err)
		}
	}
	if _, err := admin("--data-dir", s.dir, "user", "create", "--name", strings.Repeat("n", 320)); err != nil {
		t.Fatal("320 bytes must fit", err)
	}
}

func TestAdminRename(t *testing.T) {
	s := seedAccounts(t)
	adminEnv(t, time.Now(), s.zone, "oliver")
	if out, err := admin("--data-dir", s.dir, "rename", "user", "2", "--name", "Grandma"); err != nil || out != "user 2 renamed\n" {
		t.Fatalf("%q %v", out, err)
	}
	// A revoked device can still be renamed.
	if _, err := admin("--data-dir", s.dir, "revoke", "device", "1"); err != nil {
		t.Fatal(err)
	}
	if out, err := admin("--data-dir", s.dir, "rename", "device", "1", "--name", "Old MacBook"); err != nil || out != "device 1 renamed\n" {
		t.Fatalf("%q %v", out, err)
	}
	list, _ := admin("--data-dir", s.dir, "list")
	if !strings.Contains(list, "Grandma") || !strings.Contains(list, "device 1  Old MacBook  revoked") {
		t.Fatal(list)
	}
	audit, _ := admin("--data-dir", s.dir, "audit", "--limit", "1")
	if !strings.Contains(audit, "admin:oliver  rename  device:1  ok") {
		t.Fatal(audit)
	}
	for _, args := range [][]string{{"rename", "user", "99", "--name", "X"}, {"rename", "device", "99", "--name", "X"}} {
		if _, err := admin(append([]string{"--data-dir", s.dir}, args...)...); exitCode(err) != exitNotFound {
			t.Errorf("%q: %v", args, err)
		}
	}
	for _, args := range [][]string{
		{"rename"}, {"rename", "user"}, {"rename", "token", "1", "--name", "X"}, {"rename", "user", "x", "--name", "X"},
		{"rename", "user", "0", "--name", "X"}, {"rename", "user", "1"}, {"rename", "user", "1", "--name", ""},
		{"rename", "user", "1", "--name", strings.Repeat("n", 321)}, {"rename", "device", "1", "--name", strings.Repeat("n", 65)},
		{"rename", "device", "1", "--name", "a\nb"}, {"rename", "device", "1", "--name", "X", "extra"},
	} {
		if _, err := admin(append([]string{"--data-dir", s.dir}, args...)...); exitCode(err) != exitUsage {
			t.Errorf("%q: %v", args, err)
		}
	}
	if _, err := admin("--data-dir", s.dir, "rename", "user", "1", "--name", strings.Repeat("n", 320)); err != nil {
		t.Fatal(err)
	}
	if _, err := admin("--data-dir", s.dir, "rename", "device", "1", "--name", strings.Repeat("n", 64)); err != nil {
		t.Fatal(err)
	}
}

// The usage line names every command, so a reader of an old flowd's exit 1
// knows what is missing.
func TestAdminUsageLine(t *testing.T) {
	for _, part := range []string{"list [--state S] [--json]", "audit [--limit N] [--json]", "user create --name N [--json]",
		"rename user|device <id> --name N", "token create|list|revoke"} {
		if !strings.Contains(adminUsage, part) {
			t.Errorf("usage lacks %q", part)
		}
	}
	_, err := admin("--data-dir", t.TempDir())
	if exitCode(err) != exitUsage || !strings.Contains(err.Error(), "user create --name N") {
		t.Fatal(err)
	}
}
