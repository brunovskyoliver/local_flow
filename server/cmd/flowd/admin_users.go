package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// User and rename commands (specs/028-server-users-and-rewrite-warmup/contracts/admin-cli.md).
// Neither needs the identity key, so both work over SSH.

const (
	adminUserUsage   = "usage: flowd admin --data-dir <dir> [--dev] user create --name N [--json]"
	adminRenameUsage = "usage: flowd admin --data-dir <dir> [--dev] rename user|device <id> --name N"
	maxUserNameBytes = 320
	maxDeviceBytes   = 64
)

// validName is 1…limit bytes of UTF-8 with no control characters, the store's
// rule, checked here so a bad name is a usage error (exit 1).
func validName(name string, limit int) bool {
	return len(name) > 0 && len(name) <= limit && utf8.ValidString(name) && strings.IndexFunc(name, unicode.IsControl) < 0
}

// adminUser has one subcommand, create: an approved user with provider token
// that pairing tokens can then target with --user.
func adminUser(ctx context.Context, a *adminContext, args []string) error {
	if len(args) == 0 || args[0] != "create" {
		return usageError("%s", adminUserUsage)
	}
	var name string
	var asJSON bool
	fs := flag.NewFlagSet("flowd admin user create", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&name, "name", "", "")
	fs.BoolVar(&asJSON, "json", false, "")
	if err := fs.Parse(args[1:]); err != nil || fs.NArg() != 0 {
		return usageError("%s", adminUserUsage)
	}
	if !validName(name, maxUserNameBytes) {
		return usageError("--name must be 1…%d bytes with no control characters", maxUserNameBytes)
	}
	store, err := a.openStore()
	if err != nil {
		return err
	}
	defer store.Close()
	user, err := store.CreateUser(ctx, name, a.actor)
	if err != nil {
		return err
	}
	if asJSON {
		return a.writeJSON(struct {
			ID      int64  `json:"id"`
			Display string `json:"display"`
			State   string `json:"state"`
		}{user.ID, user.Display, string(user.State)})
	}
	fmt.Fprintf(a.out, "user %d %s\n", user.ID, user.State)
	return nil
}

// adminRename renames a user (display, 1…320 bytes) or a device (1…64 bytes)
// in any state. An unknown ID exits 2. The running flowd sees it at its next
// poll; nothing it serves depends on names.
func adminRename(ctx context.Context, a *adminContext, args []string) error {
	if len(args) < 2 || (args[0] != "user" && args[0] != "device") {
		return usageError("%s", adminRenameUsage)
	}
	id, err := strconv.ParseInt(args[1], 10, 64)
	if err != nil || id < 1 {
		return usageError("%s", adminRenameUsage)
	}
	var name string
	fs := flag.NewFlagSet("flowd admin rename", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&name, "name", "", "")
	if err := fs.Parse(args[2:]); err != nil || fs.NArg() != 0 {
		return usageError("%s", adminRenameUsage)
	}
	limit := maxUserNameBytes
	if args[0] == "device" {
		limit = maxDeviceBytes
	}
	if !validName(name, limit) {
		return usageError("--name must be 1…%d bytes with no control characters", limit)
	}
	store, err := a.openStore()
	if err != nil {
		return err
	}
	defer store.Close()
	if args[0] == "user" {
		err = store.RenameUser(ctx, id, name, a.actor)
	} else {
		err = store.RenameDevice(ctx, id, name, a.actor)
	}
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "%s %d renamed\n", args[0], id)
	return nil
}
