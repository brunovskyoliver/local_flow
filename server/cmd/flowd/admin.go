package main

import (
	"context"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/user"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"localflow/server/internal/accounts"
)

// flowd admin runs locally as the account that runs flowd; there is no remote
// admin API (specs/014-remote-dictation-server/contracts/flowd-cli.md).

// Exit codes of flowd admin.
const (
	exitUsage      = 1
	exitNotFound   = 2
	exitTransition = 3
)

// keychainRunner runs /usr/bin/security; tests replace it.
var keychainRunner accounts.Runner = accounts.SecurityRunner{}

// exitError carries a process exit code out of run.
type exitError struct {
	code int
	err  error
}

func (e *exitError) Error() string { return e.err.Error() }
func (e *exitError) Unwrap() error { return e.err }

// exitCode maps an error from run to the process exit status.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var exit *exitError
	if errors.As(err, &exit) {
		return exit.code
	}
	return 1
}

func usageError(format string, args ...any) error {
	return &exitError{code: exitUsage, err: fmt.Errorf(format, args...)}
}

// adminError gives store errors their admin exit code: 2 not found, 3 invalid
// transition, 1 otherwise.
func adminError(err error) error {
	var transition *accounts.TransitionError
	switch {
	case err == nil:
		return nil
	case errors.Is(err, accounts.ErrNotFound):
		return &exitError{code: exitNotFound, err: err}
	case errors.As(err, &transition):
		return &exitError{code: exitTransition, err: err}
	}
	return err
}

// adminContext is what every admin command gets.
type adminContext struct {
	dataDir  string
	keychain accounts.Keychain
	out      io.Writer
	now      func() time.Time
	location *time.Location // list and audit print local times in it
	actor    string         // admin:<unix user>
}

// The admin clock, time zone and Unix user; tests replace them.
var (
	adminNow      = time.Now
	adminLocation = time.Local
	adminUnixUser = currentUnixUser
)

// currentUnixUser is the account running flowd admin, reduced to the
// characters an audit actor may hold.
func currentUnixUser() string {
	if current, err := user.Current(); err == nil {
		if name := sanitizeUnixUser(current.Username); name != "" {
			return name
		}
	}
	return "uid" + strconv.Itoa(os.Getuid())
}

func sanitizeUnixUser(name string) string {
	var b strings.Builder
	for _, r := range name {
		if b.Len() == 64 {
			break
		}
		if r < 0x80 && (unicode.IsLetter(r) || unicode.IsDigit(r) || r == '.' || r == '_' || r == '-') {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}

// openStore opens the account store in the data directory.
func (a *adminContext) openStore() (*accounts.Store, error) {
	return accounts.Open(a.dataDir, a.now)
}

type adminCommand func(ctx context.Context, a *adminContext, args []string) error

// adminCommands is the command table; list, approve, reject, revoke and audit
// join it with their own argument parsing.
var adminCommands = map[string]adminCommand{
	"init":     adminInit,
	"identity": adminIdentity,
	"list":     adminList,
	"approve":  adminTransition("approved"),
	"reject":   adminTransition("rejected"),
	"revoke":   adminTransition("revoked"),
	"audit":    adminAudit,
}

const adminUsage = "usage: flowd admin --data-dir <dir> [--dev] <command>; commands: init, identity, " +
	"list [--state S], approve user|device <id>, reject user <id>, revoke user|device <id>, audit [--limit N]"

func runAdmin(ctx context.Context, args []string, output io.Writer) error {
	fs := flag.NewFlagSet("flowd admin", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	dataDir := fs.String("data-dir", "", "server data directory")
	dev := fs.Bool("dev", false, "development variant: use the "+accounts.ServiceDevelopment+" Keychain service")
	if err := fs.Parse(args); err != nil {
		return usageError("%s", adminUsage)
	}
	if *dataDir == "" || fs.NArg() == 0 {
		return usageError("%s", adminUsage)
	}
	command, ok := adminCommands[fs.Arg(0)]
	if !ok {
		return usageError("unknown admin command; %s", adminUsage)
	}
	service := accounts.ServiceProduction
	if *dev {
		service = accounts.ServiceDevelopment
	}
	a := &adminContext{
		dataDir:  *dataDir,
		keychain: accounts.Keychain{Runner: keychainRunner, Service: service},
		out:      output,
		now:      adminNow,
		location: adminLocation,
		actor:    accounts.AdminActor(adminUnixUser()),
	}
	return adminError(command(ctx, a, fs.Args()[1:]))
}

func noArguments(name string, args []string) error {
	if len(args) != 0 {
		return usageError("usage: flowd admin --data-dir <dir> %s", name)
	}
	return nil
}

// adminInit creates the SQLite file and the identity key; it refuses when a
// key already exists for this data directory.
func adminInit(ctx context.Context, a *adminContext, args []string) error {
	if err := noArguments("init", args); err != nil {
		return err
	}
	if _, err := a.keychain.Load(ctx, a.dataDir); err == nil {
		return accounts.ErrIdentityExists
	} else if !errors.Is(err, accounts.ErrIdentityMissing) {
		return err
	}
	store, err := a.openStore()
	if err != nil {
		return err
	}
	store.Close()
	// flowd serve refuses a data directory other users can read.
	if err := os.Chmod(a.dataDir, 0o700); err != nil {
		return err
	}
	identity, err := a.keychain.Create(ctx, a.dataDir)
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "initialized %s\nfingerprint %s\n", store.Path(), identity.Fingerprint())
	return nil
}

// adminIdentity prints the fingerprint and public key; never the private key.
func adminIdentity(ctx context.Context, a *adminContext, args []string) error {
	if err := noArguments("identity", args); err != nil {
		return err
	}
	identity, err := a.keychain.Load(ctx, a.dataDir)
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "fingerprint %s\npublic key %s\n", identity.Fingerprint(), base64.RawURLEncoding.EncodeToString(identity.PublicKey()))
	return nil
}

// adminTimeLayout is how list and audit print times: local time to the
// minute.
const adminTimeLayout = "2006-01-02 15:04"

func (a *adminContext) format(t time.Time) string { return t.In(a.location).Format(adminTimeLayout) }

// subcommandFlags parses the flags of list and audit; positional arguments
// are refused.
func subcommandFlags(name, usage string, args []string, define func(*flag.FlagSet)) error {
	fs := flag.NewFlagSet("flowd admin "+name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	define(fs)
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		return usageError("usage: flowd admin --data-dir <dir> %s", usage)
	}
	return nil
}

// adminList prints one block per user: the user line, then its devices
// indented (contracts/flowd-cli.md). --state S keeps users in state S and
// users with a device in state S. Columns are padded to the widest value;
// tokens, hashes, keys and provider subjects are never printed.
func adminList(ctx context.Context, a *adminContext, args []string) error {
	var state string
	if err := subcommandFlags("list", "list [--state pending|approved|rejected|revoked]", args, func(fs *flag.FlagSet) {
		fs.StringVar(&state, "state", "", "")
	}); err != nil {
		return err
	}
	switch state {
	case "", "pending", "approved", "rejected", "revoked":
	default:
		return usageError("--state must be pending, approved, rejected or revoked")
	}
	store, err := a.openStore()
	if err != nil {
		return err
	}
	defer store.Close()
	users, err := store.Users(ctx)
	if err != nil {
		return err
	}
	all, err := store.Devices(ctx, 0)
	if err != nil {
		return err
	}
	devices := map[int64][]accounts.Device{}
	for _, d := range all {
		devices[d.UserID] = append(devices[d.UserID], d)
	}
	var userRows, deviceRows [][]string
	var blocks [][2]int // per shown user: its row and how many device rows follow
	for _, u := range users {
		shown := state == "" || string(u.State) == state
		for _, d := range devices[u.ID] {
			shown = shown || string(d.State) == state
		}
		if !shown {
			continue
		}
		display := u.Display
		if display == "" {
			display = "-"
		}
		userRows = append(userRows, []string{"user " + strconv.FormatInt(u.ID, 10), u.Provider, display, string(u.State),
			"created " + a.format(u.CreatedAt)})
		for _, d := range devices[u.ID] {
			seen := "last seen never"
			if !d.LastSeenAt.IsZero() {
				seen = "last seen " + a.format(d.LastSeenAt)
			}
			deviceRows = append(deviceRows, []string{"device " + strconv.FormatInt(d.ID, 10), d.Name, string(d.State),
				"enrolled " + a.format(d.EnrolledAt), seen})
		}
		blocks = append(blocks, [2]int{len(userRows) - 1, len(devices[u.ID])})
	}
	userLines, deviceLines := columns(userRows), columns(deviceRows)
	next := 0
	for _, block := range blocks {
		fmt.Fprintln(a.out, userLines[block[0]])
		for range block[1] {
			fmt.Fprintln(a.out, "  "+deviceLines[next])
			next++
		}
	}
	return nil
}

// columns joins each row's cells with two spaces, padding every cell but the
// last to its column's widest value in runes.
func columns(rows [][]string) []string {
	var widths []int
	for _, row := range rows {
		for i, cell := range row {
			if i >= len(widths) {
				widths = append(widths, 0)
			}
			widths[i] = max(widths[i], utf8.RuneCountInString(cell))
		}
	}
	lines := make([]string, len(rows))
	for r, row := range rows {
		var b strings.Builder
		for i, cell := range row {
			if i > 0 {
				b.WriteString("  ")
			}
			b.WriteString(cell)
			if i < len(row)-1 {
				b.WriteString(strings.Repeat(" ", widths[i]-utf8.RuneCountInString(cell)))
			}
		}
		lines[r] = b.String()
	}
	return lines
}

// adminTransition applies approve, reject or revoke to a user or device
// through the store, which enforces the data-model transitions and writes the
// audit row in the same transaction. The running flowd applies it within
// 250 ms. Devices have no rejected state.
func adminTransition(to string) adminCommand {
	verb := strings.TrimSuffix(to, "d")
	if to == "approved" {
		verb = "approve"
	}
	return func(ctx context.Context, a *adminContext, args []string) error {
		kinds := "user|device"
		if to == "rejected" {
			kinds = "user"
		}
		usage := usageError("usage: flowd admin --data-dir <dir> %s %s <id>", verb, kinds)
		if len(args) != 2 || !strings.Contains("|"+kinds+"|", "|"+args[0]+"|") {
			return usage
		}
		id, err := strconv.ParseInt(args[1], 10, 64)
		if err != nil || id < 1 {
			return usage
		}
		store, err := a.openStore()
		if err != nil {
			return err
		}
		defer store.Close()
		if args[0] == "user" {
			err = store.SetUserState(ctx, id, accounts.UserState(to), a.actor)
		} else {
			err = store.SetDeviceState(ctx, id, accounts.DeviceState(to), a.actor)
		}
		if err != nil {
			return err
		}
		fmt.Fprintf(a.out, "%s %d %s\n", args[0], id, to)
		return nil
	}
}

// adminAudit prints audit rows newest first: time, actor, action, target and
// outcome. The rows hold identifiers and codes only.
func adminAudit(ctx context.Context, a *adminContext, args []string) error {
	limit := 50
	if err := subcommandFlags("audit", "audit [--limit N]", args, func(fs *flag.FlagSet) {
		fs.IntVar(&limit, "limit", 50, "")
	}); err != nil {
		return err
	}
	if limit < 1 || limit > accounts.MaxAuditRows {
		return usageError("--limit must be 1…%d", accounts.MaxAuditRows)
	}
	store, err := a.openStore()
	if err != nil {
		return err
	}
	defer store.Close()
	entries, err := store.AuditLog(ctx, limit)
	if err != nil {
		return err
	}
	for _, e := range entries {
		target := e.Target
		if target == "" {
			target = "-"
		}
		fmt.Fprintf(a.out, "%s  %s  %s  %s  %s\n", a.format(e.At), e.Actor, e.Action, target, e.Outcome)
	}
	return nil
}
