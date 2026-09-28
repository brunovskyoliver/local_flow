package accounts

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// fakeSecurity imitates /usr/bin/security add-generic-password (secret on
// stdin, typed twice) and find-generic-password -w.
type fakeSecurity struct {
	items map[string]string
	calls [][]string
	stdin [][]byte
	fail  error
}

type exitError int

func (e exitError) Error() string { return fmt.Sprintf("exit status %d", int(e)) }
func (e exitError) ExitCode() int { return int(e) }

func (f *fakeSecurity) Run(_ context.Context, stdin []byte, args ...string) ([]byte, error) {
	f.calls = append(f.calls, args)
	f.stdin = append(f.stdin, stdin)
	if f.fail != nil {
		return []byte("secret-looking output"), f.fail
	}
	flag := func(name string) string {
		i := slices.Index(args, name)
		if i < 0 || i+1 >= len(args) {
			return ""
		}
		return args[i+1]
	}
	key := flag("-s") + "|" + flag("-a")
	switch args[0] {
	case "add-generic-password":
		if args[len(args)-1] != "-w" {
			return nil, errors.New("secret must be read from stdin")
		}
		if _, exists := f.items[key]; exists {
			return nil, exitError(45)
		}
		lines := strings.Split(string(stdin), "\n")
		if len(lines) < 2 || lines[0] != lines[1] {
			return nil, errors.New("passwords don't match")
		}
		f.items[key] = lines[0]
		return nil, nil
	case "find-generic-password":
		secret, ok := f.items[key]
		if !ok {
			return nil, exitError(44)
		}
		return []byte(secret + "\n"), nil
	}
	return nil, errors.New("unexpected command")
}

func TestIdentityCreateAndLoad(t *testing.T) {
	security := &fakeSecurity{items: map[string]string{}}
	keychain := Keychain{Runner: security, Service: ServiceProduction}
	dir := t.TempDir()
	if _, err := keychain.Load(ctx, dir); !errors.Is(err, ErrIdentityMissing) {
		t.Fatal(err)
	}
	created, err := keychain.Create(ctx, dir)
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := keychain.Load(ctx, dir)
	if err != nil || !bytes.Equal(loaded.PublicKey(), created.PublicKey()) || len(created.PublicKey()) != 32 {
		t.Fatal(err)
	}
	if _, err := keychain.Create(ctx, dir); !errors.Is(err, ErrIdentityExists) {
		t.Fatal("a second init must be refused", err)
	}
	// The secret travels on stdin, never in argv.
	secret := security.items[ServiceProduction+"|"+dir]
	for _, args := range security.calls {
		if strings.Contains(strings.Join(args, " "), secret) {
			t.Fatal("key in argv")
		}
		if args[0] == "add-generic-password" && !slices.Equal(args, []string{"add-generic-password", "-s", ServiceProduction, "-a", dir, "-w"}) {
			t.Fatal(args)
		}
	}
	// The account is the absolute data directory; relative paths are resolved.
	relative, _ := filepath.Rel(mustGetwd(t), dir)
	if again, err := keychain.Load(ctx, relative); err != nil || !bytes.Equal(again.PublicKey(), created.PublicKey()) {
		t.Fatal("relative path", err)
	}
	// Another data directory or the development service is a different key.
	if _, err := (Keychain{Runner: security, Service: ServiceDevelopment}).Load(ctx, dir); !errors.Is(err, ErrIdentityMissing) {
		t.Fatal(err)
	}
	if _, err := keychain.Load(ctx, t.TempDir()); !errors.Is(err, ErrIdentityMissing) {
		t.Fatal(err)
	}
}

func TestServices(t *testing.T) {
	if ServiceProduction != "org.localflow.LocalFlow.remote.identity" || ServiceDevelopment != "org.localflow.LocalFlow.dev.remote.identity" {
		t.Fatal(ServiceProduction, ServiceDevelopment)
	}
}

func mustGetwd(t *testing.T) string {
	t.Helper()
	wd, err := filepath.Abs(".")
	if err != nil {
		t.Fatal(err)
	}
	return wd
}

func TestFingerprint(t *testing.T) {
	public := bytes.Repeat([]byte{0xab}, 32)
	sum := sha256.Sum256(public)
	digits := hex.EncodeToString(sum[:16])
	var groups []string
	for i := 0; i < 32; i += 4 {
		groups = append(groups, digits[i:i+4])
	}
	if got := Fingerprint(public); got != strings.Join(groups, "-") || !regexp.MustCompile(`^[0-9a-f]{4}(-[0-9a-f]{4}){7}$`).MatchString(got) {
		t.Fatal(got)
	}
}

// The private key never shows up in errors or when the identity is printed.
func TestIdentityNeverPrintsTheKey(t *testing.T) {
	security := &fakeSecurity{items: map[string]string{}}
	keychain := Keychain{Runner: security, Service: ServiceProduction}
	dir := t.TempDir()
	identity, err := keychain.Create(ctx, dir)
	if err != nil {
		t.Fatal(err)
	}
	secret := security.items[ServiceProduction+"|"+dir]
	for _, format := range []string{"%v", "%+v", "%#v", "%s"} {
		if printed := fmt.Sprintf(format, identity); strings.Contains(printed, secret) || !strings.Contains(printed, identity.Fingerprint()) {
			t.Fatalf("%s printed %q", format, printed)
		}
	}
	// A corrupt item: the error must not echo what the keychain returned.
	security.items[ServiceProduction+"|"+dir] = "zz" + secret[2:]
	_, err = keychain.Load(ctx, dir)
	if err == nil || strings.Contains(err.Error(), secret[2:]) {
		t.Fatal(err)
	}
	security.items[ServiceProduction+"|"+dir] = secret[:62]
	if _, err := keychain.Load(ctx, dir); err == nil || strings.Contains(err.Error(), secret[:62]) {
		t.Fatal("short key accepted or echoed", err)
	}
	security.fail = errors.New("security: " + secret)
	if _, err := keychain.Load(ctx, dir); err == nil || strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), "secret-looking") {
		t.Fatal(err)
	}
}
