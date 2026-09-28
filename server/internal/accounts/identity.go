package accounts

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/hpke"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os/exec"
	"path/filepath"
	"strings"
)

// Keychain services for the server identity key (data-model "Server identity
// key"); the account is the absolute data directory.
const (
	ServiceProduction  = "org.localflow.LocalFlow.remote.identity"
	ServiceDevelopment = "org.localflow.LocalFlow.dev.remote.identity"
	securityPath       = "/usr/bin/security"
	itemNotFound       = 44 // security's exit status for a missing item
)

var (
	ErrIdentityMissing = errors.New("accounts: remote identity key missing; run flowd admin init")
	ErrIdentityExists  = errors.New("accounts: remote identity key already exists")
	errKeychain        = errors.New("accounts: keychain access failed")
)

// Runner runs /usr/bin/security with args, writing stdin to it and returning
// its standard output. An error with ExitCode() reports the exit status.
type Runner interface {
	Run(ctx context.Context, stdin []byte, args ...string) ([]byte, error)
}

// SecurityRunner is the production Runner.
type SecurityRunner struct{}

func (SecurityRunner) Run(ctx context.Context, stdin []byte, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, securityPath, args...)
	cmd.Stdin = bytes.NewReader(stdin)
	return cmd.Output()
}

// Keychain stores the X25519 identity key as a generic password in the login
// Keychain of the account that runs flowd.
type Keychain struct {
	Runner  Runner
	Service string
}

// Identity is the server's long-term X25519 key pair. Printing it shows only
// the fingerprint.
type Identity struct {
	key    hpke.PrivateKey
	public []byte
}

// PrivateKey is the HPKE recipient key for channel hellos.
func (i *Identity) PrivateKey() hpke.PrivateKey { return i.key }

// PublicKey is the raw 32-byte public key.
func (i *Identity) PublicKey() []byte { return bytes.Clone(i.public) }

// Fingerprint is the fingerprint of the public key.
func (i Identity) Fingerprint() string { return Fingerprint(i.public) }

func (i Identity) String() string   { return "remote identity " + i.Fingerprint() }
func (i Identity) GoString() string { return i.String() }

// Fingerprint is the first 16 bytes of SHA-256 over the raw public key as
// eight groups of four lowercase hex digits joined by '-'.
func Fingerprint(public []byte) string {
	sum := sha256.Sum256(public)
	digits := hex.EncodeToString(sum[:16])
	groups := make([]string, 0, 8)
	for i := 0; i < len(digits); i += 4 {
		groups = append(groups, digits[i:i+4])
	}
	return strings.Join(groups, "-")
}

// Create generates and stores a new key for dataDir, refusing when one
// exists.
//
// The key goes to security on stdin: with -w as the last option, security
// prompts for the password and its confirmation, so the key never appears in
// argv where ps could show it.
func (k Keychain) Create(ctx context.Context, dataDir string) (*Identity, error) {
	account, err := filepath.Abs(dataDir)
	if err != nil {
		return nil, err
	}
	if _, err := k.Load(ctx, account); err == nil {
		return nil, ErrIdentityExists
	} else if !errors.Is(err, ErrIdentityMissing) {
		return nil, err
	}
	private, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	raw := private.Bytes()
	encoded := hex.EncodeToString(raw)
	stdin := []byte(encoded + "\n" + encoded + "\n")
	if _, err := k.Runner.Run(ctx, stdin, "add-generic-password", "-s", k.Service, "-a", account, "-w"); err != nil {
		return nil, errKeychain
	}
	return newIdentity(raw)
}

// Load reads the key for dataDir: ErrIdentityMissing when there is none.
// Errors never carry what security printed.
func (k Keychain) Load(ctx context.Context, dataDir string) (*Identity, error) {
	account, err := filepath.Abs(dataDir)
	if err != nil {
		return nil, err
	}
	out, err := k.Runner.Run(ctx, nil, "find-generic-password", "-s", k.Service, "-a", account, "-w")
	if err != nil {
		var exit interface{ ExitCode() int }
		if errors.As(err, &exit) && exit.ExitCode() == itemNotFound {
			return nil, ErrIdentityMissing
		}
		return nil, errKeychain
	}
	raw, err := hex.DecodeString(strings.TrimSpace(string(out)))
	if err != nil || len(raw) != 32 {
		return nil, errors.New("accounts: remote identity key in the keychain is malformed")
	}
	return newIdentity(raw)
}

func newIdentity(raw []byte) (*Identity, error) {
	key, err := hpke.DHKEM(ecdh.X25519()).NewPrivateKey(raw)
	if err != nil {
		return nil, errors.New("accounts: remote identity key is invalid")
	}
	return &Identity{key: key, public: key.PublicKey().Bytes()}, nil
}
