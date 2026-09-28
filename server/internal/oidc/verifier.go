// Package oidc verifies Sign in with Apple and Google ID tokens for flowd's
// remote enrollment (specs/014-remote-dictation-server/research.md R6): RS256
// only, issuer and audience per provider, exp and iat with 60 s leeway by the
// server clock, and a nonce bound to the channel. It returns the provider,
// subject and one display string, and never logs claims.
package oidc

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"slices"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// Provider endpoints and bounds.
const (
	AppleIssuer    = "https://appleid.apple.com"
	AppleJWKSURL   = "https://appleid.apple.com/auth/keys"
	GoogleJWKSURL  = "https://www.googleapis.com/oauth2/v3/certs"
	Leeway         = 60 * time.Second
	MaxTokenBytes  = 16384
	maxSubject     = 255
	maxDisplay     = 320
	defaultTimeout = 10 * time.Second
)

// GoogleIssuers are the two issuer spellings Google uses.
var GoogleIssuers = []string{"https://accounts.google.com", "accounts.google.com"}

var (
	// ErrInvalid refuses an ID token (channel code unauthorized).
	ErrInvalid = errors.New("oidc: ID token not accepted")
	// ErrProviderDisabled refuses Google when no client ID is configured.
	ErrProviderDisabled = errors.New("oidc: provider not enabled on this server")
	// ErrUnavailable means the provider's keys could not be fetched.
	ErrUnavailable = errors.New("oidc: provider keys unavailable")
)

// refusal is an ErrInvalid with a content-free reason for tests.
type refusal struct{ reason string }

func (r *refusal) Error() string        { return ErrInvalid.Error() + ": " + r.reason }
func (r *refusal) Is(target error) bool { return target == ErrInvalid }

func invalid(reason string) error { return &refusal{reason} }

// Config configures a Verifier.
type Config struct {
	// AppleAudiences are the accepted Apple aud values (--apple-audience).
	AppleAudiences []string
	// GoogleClientIDs are the accepted Google aud values
	// (--google-client-id); Google is refused when empty.
	GoogleClientIDs []string
	// HTTPClient fetches JWKS; default has a 10 s timeout.
	HTTPClient *http.Client
	// Now is the server clock; default time.Now.
	Now func() time.Time
	// TestIssuer and TestJWKS (debug builds only) replace both providers'
	// issuers and key sources with a local issuer and a JWKS file.
	TestIssuer string
	TestJWKS   string
}

// Identity is what a verified token yields. Display is the email, or the name
// when there is no email; it is shown only by flowd admin.
type Identity struct {
	Provider string
	Subject  string
	Display  string
}

// String and GoString name the provider only, so an Identity in a log line
// never carries claims.
func (i Identity) String() string   { return "oidc identity " + i.Provider }
func (i Identity) GoString() string { return i.String() }

type provider struct {
	issuers       []string
	audiences     []string
	keys          keySource
	nonce         func(binding []byte) string
	emailVerified bool
}

// Verifier checks ID tokens. It is safe for concurrent use.
type Verifier struct {
	providers map[string]*provider
	now       func() time.Time
}

// New builds a Verifier. Apple needs at least one audience.
func New(cfg Config) (*Verifier, error) {
	if len(cfg.AppleAudiences) == 0 || slices.Contains(cfg.AppleAudiences, "") || slices.Contains(cfg.GoogleClientIDs, "") {
		return nil, errors.New("oidc: audiences must be non-empty")
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: defaultTimeout}
	}
	v := &Verifier{now: cfg.Now, providers: map[string]*provider{
		"apple": {
			issuers: []string{AppleIssuer}, audiences: slices.Clone(cfg.AppleAudiences), nonce: appleNonce,
			keys: &remoteKeys{url: AppleJWKSURL, client: cfg.HTTPClient, now: cfg.Now},
		},
	}}
	if len(cfg.GoogleClientIDs) > 0 {
		v.providers["google"] = &provider{
			issuers: GoogleIssuers, audiences: slices.Clone(cfg.GoogleClientIDs), nonce: googleNonce, emailVerified: true,
			keys: &remoteKeys{url: GoogleJWKSURL, client: cfg.HTTPClient, now: cfg.Now},
		}
	}
	if cfg.TestIssuer != "" || cfg.TestJWKS != "" {
		keys, err := testIssuerKeys(cfg.TestIssuer, cfg.TestJWKS)
		if err != nil {
			return nil, err
		}
		for _, p := range v.providers {
			p.issuers, p.keys = []string{cfg.TestIssuer}, keys
		}
	}
	return v, nil
}

// appleNonce: the app sends SHA-256 of the channel nonce to Apple, which puts
// it in the token as lowercase hex.
func appleNonce(binding []byte) string {
	sum := sha256.Sum256([]byte(base64.RawURLEncoding.EncodeToString(binding)))
	return hex.EncodeToString(sum[:])
}

func googleNonce(binding []byte) string { return base64.RawURLEncoding.EncodeToString(binding) }

type header struct {
	Alg string `json:"alg"`
	Kid string `json:"kid"`
}

type claims struct {
	Iss           string          `json:"iss"`
	Aud           json.RawMessage `json:"aud"`
	Sub           *string         `json:"sub"`
	Exp           json.RawMessage `json:"exp"`
	Iat           json.RawMessage `json:"iat"`
	Nonce         string          `json:"nonce"`
	Email         string          `json:"email"`
	EmailVerified json.RawMessage `json:"email_verified"`
	Name          string          `json:"name"`
}

// Verify checks idToken for providerName ("apple" or "google") against the
// channel binding. Errors are ErrInvalid, ErrProviderDisabled or
// ErrUnavailable and never contain claims.
func (v *Verifier) Verify(ctx context.Context, providerName, idToken string, binding []byte) (Identity, error) {
	p, ok := v.providers[providerName]
	if !ok {
		if providerName == "google" {
			return Identity{}, ErrProviderDisabled
		}
		return Identity{}, invalid("unknown provider")
	}
	if len(idToken) > MaxTokenBytes {
		return Identity{}, invalid("token too long")
	}
	parts := strings.Split(idToken, ".")
	if len(parts) != 3 {
		return Identity{}, invalid("not a JWS compact serialization")
	}
	var decoded [3][]byte
	for i, part := range parts {
		var err error
		if decoded[i], err = base64.RawURLEncoding.Strict().DecodeString(part); err != nil {
			return Identity{}, invalid("segment not base64url")
		}
	}
	var h header
	if json.Unmarshal(decoded[0], &h) != nil {
		return Identity{}, invalid("header not JSON")
	}
	if h.Alg != "RS256" {
		return Identity{}, invalid("alg not RS256")
	}
	if h.Kid == "" {
		return Identity{}, invalid("kid missing")
	}
	key, err := p.keys.key(ctx, h.Kid)
	if err != nil {
		return Identity{}, err
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], decoded[2]) != nil {
		return Identity{}, invalid("signature")
	}
	var c claims
	if json.Unmarshal(decoded[1], &c) != nil {
		return Identity{}, invalid("claims not JSON")
	}
	if !slices.Contains(p.issuers, c.Iss) {
		return Identity{}, invalid("issuer")
	}
	if !audienceAccepted(c.Aud, p.audiences) {
		return Identity{}, invalid("audience")
	}
	now := v.now()
	exp, okExp := seconds(c.Exp)
	iat, okIat := seconds(c.Iat)
	if !okExp || !okIat {
		return Identity{}, invalid("exp or iat missing")
	}
	if now.After(exp.Add(Leeway)) {
		return Identity{}, invalid("expired")
	}
	if iat.After(now.Add(Leeway)) {
		return Identity{}, invalid("issued in the future")
	}
	if want := p.nonce(binding); subtle.ConstantTimeCompare([]byte(c.Nonce), []byte(want)) != 1 {
		return Identity{}, invalid("nonce")
	}
	if p.emailVerified && string(bytes.TrimSpace(c.EmailVerified)) != "true" && string(bytes.TrimSpace(c.EmailVerified)) != `"true"` {
		return Identity{}, invalid("email not verified")
	}
	if c.Sub == nil || *c.Sub == "" || len(*c.Sub) > maxSubject || hasControl(*c.Sub) {
		return Identity{}, invalid("subject")
	}
	display := c.Email
	if display == "" {
		display = c.Name
	}
	return Identity{Provider: providerName, Subject: *c.Sub, Display: cleanDisplay(display)}, nil
}

// audienceAccepted accepts a string aud, or an array holding an accepted
// value.
func audienceAccepted(raw json.RawMessage, accepted []string) bool {
	var single string
	if json.Unmarshal(raw, &single) == nil {
		return single != "" && slices.Contains(accepted, single)
	}
	var list []string
	if json.Unmarshal(raw, &list) != nil {
		return false
	}
	for _, aud := range list {
		if aud != "" && slices.Contains(accepted, aud) {
			return true
		}
	}
	return false
}

// seconds reads a NumericDate: a JSON number, never a string.
func seconds(raw json.RawMessage) (time.Time, bool) {
	var f float64
	if trimmed := bytes.TrimSpace(raw); len(trimmed) == 0 || trimmed[0] == '"' || json.Unmarshal(trimmed, &f) != nil {
		return time.Time{}, false
	}
	if math.IsNaN(f) || math.IsInf(f, 0) || f < 0 || f > 1e12 {
		return time.Time{}, false
	}
	whole, frac := math.Modf(f)
	return time.Unix(int64(whole), int64(frac*1e9)), true
}

func hasControl(s string) bool {
	return !utf8.ValidString(s) || strings.IndexFunc(s, unicode.IsControl) >= 0
}

// cleanDisplay drops control characters and bidirectional overrides and cuts
// to 320 bytes on a rune boundary.
func cleanDisplay(s string) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.IsControl(r) || r == utf8.RuneError || (r >= 0x202a && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069) {
			continue
		}
		if b.Len()+utf8.RuneLen(r) > maxDisplay {
			break
		}
		b.WriteRune(r)
	}
	return strings.TrimSpace(b.String())
}
