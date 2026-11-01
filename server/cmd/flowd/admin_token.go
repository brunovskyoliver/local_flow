package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"strconv"
	"strings"
	"time"

	"localflow/server/internal/accounts"
)

const adminTokenUsage = "usage: flowd admin --data-dir <dir> [--dev] token create --label L [--user ID] " +
	"[--ttl 1h|24h|7d] [--address ORIGIN]... [--json] | token list [--json] | token revoke ID"

// adminPairingToken manages pairing tokens (specs/027-remote-pairing/contracts/pairing.md).
func adminPairingToken(ctx context.Context, a *adminContext, args []string) error {
	if len(args) == 0 {
		return usageError("%s", adminTokenUsage)
	}
	switch args[0] {
	case "create":
		return adminTokenCreate(ctx, a, args[1:])
	case "list":
		return adminTokenList(ctx, a, args[1:])
	case "revoke":
		return adminTokenRevoke(ctx, a, args[1:])
	}
	return usageError("%s", adminTokenUsage)
}

// adminTokenCreate needs the identity key, because the token carries the public
// key. It prints the value once; nothing can print it again.
func adminTokenCreate(ctx context.Context, a *adminContext, args []string) error {
	var label, ttl string
	var addresses []string
	var userID int64
	var asJSON bool
	fs := flag.NewFlagSet("flowd admin token create", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&label, "label", "", "")
	fs.Int64Var(&userID, "user", 0, "")
	fs.StringVar(&ttl, "ttl", "24h", "")
	fs.Func("address", "", func(v string) error { addresses = append(addresses, v); return nil })
	fs.BoolVar(&asJSON, "json", false, "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || label == "" || userID < 0 {
		return usageError("%s", adminTokenUsage)
	}
	lifetimes := map[string]time.Duration{"1h": time.Hour, "24h": accounts.DefaultPairingLifetime, "7d": 7 * 24 * time.Hour}
	lifetime, ok := lifetimes[ttl]
	if !ok {
		return usageError("--ttl must be 1h, 24h or 7d")
	}
	for _, address := range addresses {
		if !validOrigin(address) {
			return usageError("--address must be an http:// or https:// origin with no path")
		}
	}
	identity, err := a.keychain.Load(ctx, a.dataDir)
	if errors.Is(err, accounts.ErrIdentityMissing) {
		return err
	}
	if err != nil {
		return fmt.Errorf("unlock the login Keychain, then try again: %w", err)
	}
	store, err := a.openStore()
	if err != nil {
		return err
	}
	defer store.Close()
	value, row, err := store.CreatePairingToken(ctx, identity.PublicKey(), label, userID, lifetime, a.actor)
	if err != nil {
		return err
	}
	link := ""
	if len(addresses) > 0 {
		link = a.pairingLink(addresses, value)
	}
	if asJSON {
		return json.NewEncoder(a.out).Encode(struct {
			ID        int64  `json:"id"`
			Label     string `json:"label"`
			ExpiresAt string `json:"expires_at"`
			Token     string `json:"token"`
			Link      string `json:"link"`
		}{row.ID, row.Label, row.ExpiresAt.UTC().Format(time.RFC3339), value, link})
	}
	fmt.Fprintf(a.out, "token %d %s expires %s\n%s\n", row.ID, row.Label, a.format(row.ExpiresAt), value)
	if link != "" {
		fmt.Fprintln(a.out, link)
	}
	return nil
}

// validOrigin accepts scheme and host with an optional port, nothing else.
// Which hosts may use http:// is the client's rule (FR-012a).
func validOrigin(text string) bool {
	u, err := url.Parse(text)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != "" && u.User == nil &&
		(u.Path == "" || u.Path == "/") && u.RawQuery == "" && u.Fragment == ""
}

// pairingLink is the app link: the token stays in the fragment. Development
// data directories get the development app's scheme.
func (a *adminContext) pairingLink(addresses []string, token string) string {
	scheme := "localflow"
	if a.keychain.Service == accounts.ServiceDevelopment {
		scheme = "localflow-dev"
	}
	query := make([]string, len(addresses))
	for i, address := range addresses {
		query[i] = "address=" + url.QueryEscape(address)
	}
	return scheme + "://pair?" + strings.Join(query, "&") + "#token=" + token
}

// adminTokenList prints no value or hash; the store doesn't return them. User
// and device are 0 until the token is redeemed, unless it targets a user.
func adminTokenList(ctx context.Context, a *adminContext, args []string) error {
	var asJSON bool
	if err := subcommandFlags("token list", "token list [--json]", args, func(fs *flag.FlagSet) {
		fs.BoolVar(&asJSON, "json", false, "")
	}); err != nil {
		return err
	}
	store, err := a.openStore()
	if err != nil {
		return err
	}
	defer store.Close()
	tokens, err := store.PairingTokens(ctx)
	if err != nil {
		return err
	}
	if asJSON {
		type row struct {
			ID        int64  `json:"id"`
			Label     string `json:"label"`
			State     string `json:"state"`
			UserID    int64  `json:"user_id"`
			DeviceID  int64  `json:"device_id"`
			CreatedAt string `json:"created_at"`
			ExpiresAt string `json:"expires_at"`
		}
		rows := []row{}
		for _, t := range tokens {
			rows = append(rows, row{t.ID, t.Label, string(t.State), t.UserID, t.DeviceID,
				t.CreatedAt.UTC().Format(time.RFC3339), t.ExpiresAt.UTC().Format(time.RFC3339)})
		}
		return json.NewEncoder(a.out).Encode(rows)
	}
	var rows [][]string
	for _, t := range tokens {
		rows = append(rows, []string{"token " + strconv.FormatInt(t.ID, 10), t.Label, string(t.State),
			"user " + strconv.FormatInt(t.UserID, 10), "device " + strconv.FormatInt(t.DeviceID, 10),
			"created " + a.format(t.CreatedAt), "expires " + a.format(t.ExpiresAt)})
	}
	for _, line := range columns(rows) {
		fmt.Fprintln(a.out, line)
	}
	return nil
}

func adminTokenRevoke(ctx context.Context, a *adminContext, args []string) error {
	usage := usageError("usage: flowd admin --data-dir <dir> token revoke <id>")
	if len(args) != 1 {
		return usage
	}
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil || id < 1 {
		return usage
	}
	store, err := a.openStore()
	if err != nil {
		return err
	}
	defer store.Close()
	if err := store.RevokePairingToken(ctx, id, a.actor); err != nil {
		return err
	}
	fmt.Fprintf(a.out, "token %d revoked\n", id)
	return nil
}
