package remote

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"errors"
	"log"

	"localflow/server/internal/accounts"
	"localflow/server/internal/oidc"
)

// Device signature labels (contract "Enrollment" and "Refresh").
const (
	EnrollSignatureLabel  = "localflow-v1-enroll"
	RefreshSignatureLabel = "localflow-v1-refresh"
)

// IDTokenVerifier checks a provider ID token against the channel binding
// (oidc.Verifier).
type IDTokenVerifier interface {
	Verify(ctx context.Context, provider, idToken string, binding []byte) (oidc.Identity, error)
}

// AccountsConfig configures the enroll and refresh operations.
type AccountsConfig struct {
	Store    *accounts.Store
	Verifier IDTokenVerifier
	// Reload makes the listener's snapshot see a write at once (the
	// watcher's Poll), so a fresh access token opens a session without
	// waiting for the 250 ms poll and a reuse revocation closes channels
	// immediately. May be nil.
	Reload func(ctx context.Context) error
	Logger *log.Logger
}

// AccountOperations returns the enroll and refresh operations (User Story 2).
func AccountOperations(cfg AccountsConfig) Operations {
	if cfg.Logger == nil {
		cfg.Logger = log.New(discard{}, "", 0)
	}
	a := &accountOps{cfg}
	return Operations{
		PurposeEnroll:  {"enroll": a.enroll},
		PurposeRefresh: {"refresh": a.refresh},
	}
}

type accountOps struct{ cfg AccountsConfig }

func coded(code ErrorCode, reason string) error { return &Error{code, reason} }

// audit writes one content-free row; a failure is logged by code only.
func (a *accountOps) audit(ctx context.Context, c *Conn, entry accounts.AuditEntry) {
	if err := a.cfg.Store.Audit(ctx, entry); err != nil {
		a.cfg.Logger.Printf("remote channel=%d event=audit_failed action=%s code=internal", c.ID(), entry.Action)
	}
}

func (a *accountOps) reload(ctx context.Context) {
	if a.cfg.Reload != nil {
		_ = a.cfg.Reload(ctx)
	}
}

// verifyDeviceSignature checks a DER ECDSA P-256 signature over SHA-256 of
// the concatenated parts with an X9.63 uncompressed public key, as CryptoKit's
// Secure Enclave signing produces it.
func verifyDeviceSignature(publicKey, signature []byte, parts ...[]byte) bool {
	key, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), publicKey)
	if err != nil {
		return false
	}
	digest := sha256.Sum256(bytes.Join(parts, nil))
	return ecdsa.VerifyASN1(key, digest[:], signature)
}

// enroll: the device key's signature over the channel binding, then the ID
// token, then the account. A new identity becomes a pending user; a new key
// becomes a pending device of that user with a new refresh lineage. A
// rejected user gets state rejected and nothing else; a revoked user or
// device gets revoked.
func (a *accountOps) enroll(ctx context.Context, c *Conn, m Message) (Operation, error) {
	message := m.(Enroll)
	outcome, user, device := CodeInternal, int64(0), int64(0)
	defer func() {
		a.cfg.Logger.Printf("remote channel=%d op=enroll user=%d device=%d code=%s", c.ID(), user, device, outcome)
	}()
	if c.Now().Sub(c.ReadyAt()) > EnrollIdleTimeout {
		outcome = CodeUnauthorized
		return nil, coded(outcome, "enroll more than 5 minutes after ready")
	}
	binding := c.Binding()
	if !verifyDeviceSignature(message.DeviceKey, message.Signature, []byte(EnrollSignatureLabel), binding) {
		outcome = CodeUnauthorized
		a.audit(ctx, c, accounts.AuditEntry{Actor: accounts.SystemActor, Action: "sign_in", Outcome: string(outcome)})
		return nil, coded(outcome, "device signature")
	}
	identity, err := a.cfg.Verifier.Verify(ctx, message.Provider, message.IDToken, binding)
	if err != nil {
		outcome = CodeUnauthorized
		if errors.Is(err, oidc.ErrUnavailable) {
			outcome = CodeInternal
		}
		a.audit(ctx, c, accounts.AuditEntry{Actor: accounts.SystemActor, Action: "sign_in", Outcome: string(outcome)})
		return nil, coded(outcome, "id token")
	}
	account, _, err := a.cfg.Store.EnsureUser(ctx, identity.Provider, identity.Subject, identity.Display)
	switch {
	case errors.Is(err, accounts.ErrPendingLimit):
		outcome = CodeBusy
		a.audit(ctx, c, accounts.AuditEntry{Actor: accounts.SystemActor, Action: "rate_limited", Outcome: string(outcome)})
		return nil, coded(outcome, "pending account limit")
	case err != nil:
		return nil, coded(CodeInternal, "ensure user")
	}
	user = account.ID
	actor, userTarget := accounts.UserActor(user), accounts.UserTarget(user)
	a.audit(ctx, c, accounts.AuditEntry{Actor: actor, Action: "sign_in", Target: userTarget, Outcome: "ok"})
	switch account.State {
	case accounts.UserRejected:
		outcome = CodeNotApproved
		a.audit(ctx, c, accounts.AuditEntry{Actor: actor, Action: "enroll", Target: userTarget, Outcome: string(outcome)})
		return nil, c.Send(ctx, Enrolled{Op: message.Op, State: "rejected"})
	case accounts.UserRevoked:
		outcome = CodeRevoked
		a.audit(ctx, c, accounts.AuditEntry{Actor: actor, Action: "enroll", Target: userTarget, Outcome: string(outcome)})
		return nil, coded(outcome, "user revoked")
	}
	row, err := a.enrollDevice(ctx, user, message)
	if row.ID != 0 {
		device = row.ID
	}
	if err != nil {
		outcome = CodeOf(err)
		target := userTarget
		if device != 0 {
			target = accounts.DeviceTarget(device)
		}
		a.audit(ctx, c, accounts.AuditEntry{Actor: actor, Action: "enroll", Target: target, Outcome: string(outcome)})
		return nil, err
	}
	token, _, err := a.cfg.Store.IssueRefresh(ctx, device)
	if err != nil {
		return nil, coded(CodeInternal, "issue refresh")
	}
	state := "pending"
	if account.State == accounts.UserApproved && row.State == accounts.DeviceApproved {
		state = "approved"
	}
	outcome = "ok"
	a.audit(ctx, c, accounts.AuditEntry{Actor: actor, Action: "enroll", Target: accounts.DeviceTarget(device), Outcome: "ok"})
	return nil, c.Send(ctx, Enrolled{Op: message.Op, State: state, RefreshToken: token})
}

// enrollDevice adds the key as a pending device of user, or finds it when the
// same user enrolls the same key again (a reinstall that lost its tokens).
// A key held by another user is unauthorized; a revoked device stays revoked.
func (a *accountOps) enrollDevice(ctx context.Context, user int64, message Enroll) (accounts.Device, error) {
	row, err := a.cfg.Store.AddDevice(ctx, user, message.DeviceName, message.DeviceKey)
	if err == nil {
		return row, nil
	}
	if !errors.Is(err, accounts.ErrDuplicateKey) {
		return accounts.Device{}, coded(CodeInternal, "add device")
	}
	row, err = a.cfg.Store.DeviceByKey(ctx, message.DeviceKey)
	switch {
	case err != nil:
		return accounts.Device{}, coded(CodeInternal, "device by key")
	case row.UserID != user:
		return accounts.Device{}, coded(CodeUnauthorized, "key enrolled by another user")
	case row.State == accounts.DeviceRevoked:
		return row, coded(CodeRevoked, "device revoked")
	}
	return row, nil
}
