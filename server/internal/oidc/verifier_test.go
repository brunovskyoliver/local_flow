package oidc

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"localflow/server/internal/oidc/oidctest"
)

type testClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *testClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *testClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

var (
	ctx     = context.Background()
	binding = bytes.Repeat([]byte{0xab}, 32)
)

type fixture struct {
	t         *testing.T
	clock     *testClock
	transport *oidctest.Transport
	verifier  *Verifier
}

func newFixture(t *testing.T, google []string) *fixture {
	t.Helper()
	clock := &testClock{now: time.Unix(1_790_000_000, 0)}
	transport := oidctest.NewTransport(t)
	verifier, err := New(Config{
		AppleAudiences:  []string{"org.localflow.LocalFlow", "org.localflow.LocalFlow.dev"},
		GoogleClientIDs: google,
		HTTPClient:      transport.Client(),
		Now:             clock.Now,
	})
	if err != nil {
		t.Fatal(err)
	}
	return &fixture{t, clock, transport, verifier}
}

func (f *fixture) appleClaims() map[string]any {
	now := f.clock.Now().Unix()
	return map[string]any{
		"iss": AppleIssuer, "aud": "org.localflow.LocalFlow", "sub": "001234.abcdef",
		"iat": now, "exp": now + 600, "nonce": oidctest.AppleNonce(binding),
		"email": "oliver@example.com", "email_verified": "true",
	}
}

func (f *fixture) googleClaims() map[string]any {
	now := f.clock.Now().Unix()
	return map[string]any{
		"iss": "https://accounts.google.com", "aud": "client-1.apps.googleusercontent.com", "sub": "1098765",
		"iat": now, "exp": now + 3600, "nonce": oidctest.GoogleNonce(binding),
		"email": "oliver@gmail.com", "email_verified": true, "name": "Oliver",
	}
}

func with(claims map[string]any, changes map[string]any) map[string]any {
	out := map[string]any{}
	for k, v := range claims {
		out[k] = v
	}
	for k, v := range changes {
		if v == nil {
			delete(out, k)
		} else {
			out[k] = v
		}
	}
	return out
}

func TestAppleToken(t *testing.T) {
	f := newFixture(t, nil)
	identity, err := f.verifier.Verify(ctx, "apple", oidctest.Mint(t, nil, f.appleClaims()), binding)
	if err != nil {
		t.Fatal(err)
	}
	if identity != (Identity{Provider: "apple", Subject: "001234.abcdef", Display: "oliver@example.com"}) {
		t.Fatalf("%+v", identity)
	}
	if got := f.transport.Requests(); len(got) != 1 || got[0] != AppleJWKSURL {
		t.Fatal(got)
	}
	// The development audience from --apple-audience is accepted too; Apple
	// needs no email_verified and may omit the email.
	claims := with(f.appleClaims(), map[string]any{"aud": "org.localflow.LocalFlow.dev", "email": nil, "email_verified": nil})
	identity, err = f.verifier.Verify(ctx, "apple", oidctest.Mint(t, nil, claims), binding)
	if err != nil || identity.Display != "" || identity.Subject != "001234.abcdef" {
		t.Fatal(identity, err)
	}
}

func TestGoogleToken(t *testing.T) {
	f := newFixture(t, []string{"client-1.apps.googleusercontent.com", "client-2.apps.googleusercontent.com"})
	for _, issuer := range []string{"https://accounts.google.com", "accounts.google.com"} {
		claims := with(f.googleClaims(), map[string]any{"iss": issuer})
		identity, err := f.verifier.Verify(ctx, "google", oidctest.Mint(t, nil, claims), binding)
		if err != nil || identity != (Identity{Provider: "google", Subject: "1098765", Display: "oliver@gmail.com"}) {
			t.Fatal(issuer, identity, err)
		}
	}
	if got := f.transport.Requests(); len(got) != 1 || got[0] != GoogleJWKSURL {
		t.Fatal(got)
	}
	// Display falls back to the name.
	claims := with(f.googleClaims(), map[string]any{"email": nil, "email_verified": true, "aud": "client-2.apps.googleusercontent.com"})
	if identity, err := f.verifier.Verify(ctx, "google", oidctest.Mint(t, nil, claims), binding); err != nil || identity.Display != "Oliver" {
		t.Fatal(identity, err)
	}
}

// Google sign-in is refused when --google-client-id is unset.
func TestGoogleRefusedWithoutClientID(t *testing.T) {
	f := newFixture(t, nil)
	_, err := f.verifier.Verify(ctx, "google", oidctest.Mint(t, nil, f.googleClaims()), binding)
	if !errors.Is(err, ErrProviderDisabled) {
		t.Fatal(err)
	}
	if len(f.transport.Requests()) != 0 {
		t.Fatal("a refused provider must not fetch keys")
	}
	if _, err := f.verifier.Verify(ctx, "github", oidctest.Mint(t, nil, f.googleClaims()), binding); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
}

func TestRefusals(t *testing.T) {
	f := newFixture(t, []string{"client-1.apps.googleusercontent.com"})
	now := f.clock.Now().Unix()
	apple, google := f.appleClaims(), f.googleClaims()
	for name, tc := range map[string]struct {
		provider string
		header   map[string]any
		claims   map[string]any
	}{
		"apple wrong issuer":           {"apple", nil, with(apple, map[string]any{"iss": "https://accounts.google.com"})},
		"apple issuer without https":   {"apple", nil, with(apple, map[string]any{"iss": "appleid.apple.com"})},
		"google wrong issuer":          {"google", nil, with(google, map[string]any{"iss": AppleIssuer})},
		"apple wrong audience":         {"apple", nil, with(apple, map[string]any{"aud": "org.example.Other"})},
		"apple google audience":        {"apple", nil, with(apple, map[string]any{"aud": "client-1.apps.googleusercontent.com"})},
		"google wrong audience":        {"google", nil, with(google, map[string]any{"aud": "org.localflow.LocalFlow"})},
		"audience missing":             {"apple", nil, with(apple, map[string]any{"aud": nil})},
		"alg none":                     {"apple", map[string]any{"alg": "none"}, apple},
		"alg HS256":                    {"apple", map[string]any{"alg": "HS256"}, apple},
		"alg RS512":                    {"apple", map[string]any{"alg": "RS512"}, apple},
		"alg PS256":                    {"apple", map[string]any{"alg": "PS256"}, apple},
		"alg missing":                  {"apple", map[string]any{"alg": nil}, apple},
		"kid missing":                  {"apple", map[string]any{"kid": nil}, apple},
		"expired past leeway":          {"apple", nil, with(apple, map[string]any{"exp": now - 61})},
		"issued in the future":         {"apple", nil, with(apple, map[string]any{"iat": now + 61})},
		"exp missing":                  {"apple", nil, with(apple, map[string]any{"exp": nil})},
		"iat missing":                  {"apple", nil, with(apple, map[string]any{"iat": nil})},
		"exp a string":                 {"apple", nil, with(apple, map[string]any{"exp": "9999999999"})},
		"apple nonce in google form":   {"apple", nil, with(apple, map[string]any{"nonce": oidctest.GoogleNonce(binding)})},
		"google nonce in apple form":   {"google", nil, with(google, map[string]any{"nonce": oidctest.AppleNonce(binding)})},
		"nonce of another binding":     {"apple", nil, with(apple, map[string]any{"nonce": oidctest.AppleNonce(make([]byte, 32))})},
		"nonce missing":                {"google", nil, with(google, map[string]any{"nonce": nil})},
		"google email not verified":    {"google", nil, with(google, map[string]any{"email_verified": false})},
		"google email_verified absent": {"google", nil, with(google, map[string]any{"email_verified": nil})},
		"google email_verified string": {"google", nil, with(google, map[string]any{"email_verified": "false"})},
		"subject missing":              {"apple", nil, with(apple, map[string]any{"sub": nil})},
		"subject empty":                {"apple", nil, with(apple, map[string]any{"sub": ""})},
		"subject over 255 bytes":       {"apple", nil, with(apple, map[string]any{"sub": strings.Repeat("s", 256)})},
	} {
		token := oidctest.Mint(t, tc.header, tc.claims)
		identity, err := f.verifier.Verify(ctx, tc.provider, token, binding)
		if !errors.Is(err, ErrInvalid) {
			t.Errorf("%s: %+v %v", name, identity, err)
			continue
		}
		// Errors never carry claims.
		for _, claim := range []string{"001234.abcdef", "1098765", "oliver@"} {
			if strings.Contains(err.Error(), claim) {
				t.Errorf("%s: error %q carries a claim", name, err)
			}
		}
	}
}

func TestSignatureAndShape(t *testing.T) {
	f := newFixture(t, nil)
	token := oidctest.Mint(t, nil, f.appleClaims())
	parts := strings.Split(token, ".")
	other := strings.Split(oidctest.Mint(t, nil, with(f.appleClaims(), map[string]any{"sub": "someone-else"})), ".")
	for name, bad := range map[string]string{
		"payload swapped":   parts[0] + "." + other[1] + "." + parts[2],
		"signature cut":     parts[0] + "." + parts[1] + "." + parts[2][:len(parts[2])-4],
		"signature empty":   parts[0] + "." + parts[1] + ".",
		"two parts":         parts[0] + "." + parts[1],
		"four parts":        token + ".x",
		"payload not json":  parts[0] + ".bm90IGpzb24." + parts[2],
		"padding in base64": parts[0] + "=." + parts[1] + "." + parts[2],
		"over 16 KiB":       parts[0] + "." + strings.Repeat("A", 16384) + "." + parts[2],
	} {
		if _, err := f.verifier.Verify(ctx, "apple", bad, binding); !errors.Is(err, ErrInvalid) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

// exp and iat are checked with 60 s leeway by the injected server clock.
func TestLeeway(t *testing.T) {
	f := newFixture(t, nil)
	now := f.clock.Now().Unix()
	for name, claims := range map[string]map[string]any{
		"expired 59 s ago":      with(f.appleClaims(), map[string]any{"exp": now - 59}),
		"issued 59 s from now":  with(f.appleClaims(), map[string]any{"iat": now + 59}),
		"exp a float in leeway": with(f.appleClaims(), map[string]any{"exp": float64(now) - 30.5}),
	} {
		if _, err := f.verifier.Verify(ctx, "apple", oidctest.Mint(t, nil, claims), binding); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	token := oidctest.Mint(t, nil, f.appleClaims()) // exp now+600
	f.clock.Advance(660 * time.Second)
	if _, err := f.verifier.Verify(ctx, "apple", token, binding); err != nil {
		t.Fatal("at exp+60 s", err)
	}
	f.clock.Advance(time.Second)
	if _, err := f.verifier.Verify(ctx, "apple", token, binding); !errors.Is(err, ErrInvalid) {
		t.Fatal("past exp+60 s by the server clock", err)
	}
}

// Keys are cached per Cache-Control max-age, clamped to 5 minutes…24 hours.
func TestJWKSCache(t *testing.T) {
	for _, tc := range []struct {
		cacheControl string
		lifetime     time.Duration
	}{
		{"", MinCache},
		{"no-store", MinCache},
		{"public, max-age=60", MinCache},
		{"public, max-age=3600, must-revalidate", time.Hour},
		{"max-age=172800", MaxCache},
		{"max-age=nonsense", MinCache},
	} {
		f := newFixture(t, nil)
		f.transport.CacheControl = tc.cacheControl
		verify := func() {
			t.Helper()
			if _, err := f.verifier.Verify(ctx, "apple", oidctest.Mint(t, nil, f.appleClaims()), binding); err != nil {
				t.Fatal(tc.cacheControl, err)
			}
		}
		verify()
		f.clock.Advance(tc.lifetime - time.Second)
		verify()
		if n := len(f.transport.Requests()); n != 1 {
			t.Fatalf("%q: %d fetches before the cache lifetime", tc.cacheControl, n)
		}
		f.clock.Advance(time.Second)
		verify()
		if n := len(f.transport.Requests()); n != 2 {
			t.Fatalf("%q: %d fetches at the cache lifetime", tc.cacheControl, n)
		}
	}
}

// An unknown kid refetches at most once a minute (key rotation).
func TestUnknownKidRefetch(t *testing.T) {
	f := newFixture(t, nil)
	f.transport.Set([]byte(`{"keys":[]}`), "max-age=86400")
	token := oidctest.Mint(t, nil, f.appleClaims())
	if _, err := f.verifier.Verify(ctx, "apple", token, binding); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	f.transport.Set(oidctest.JWKS(t), "max-age=86400")
	for range 5 {
		if _, err := f.verifier.Verify(ctx, "apple", token, binding); !errors.Is(err, ErrInvalid) {
			t.Fatal("refetched within a minute", err)
		}
	}
	if n := len(f.transport.Requests()); n != 1 {
		t.Fatalf("%d fetches", n)
	}
	f.clock.Advance(RefetchInterval)
	if _, err := f.verifier.Verify(ctx, "apple", oidctest.Mint(t, nil, f.appleClaims()), binding); err != nil {
		t.Fatal("rotated key after a minute", err)
	}
	if n := len(f.transport.Requests()); n != 2 {
		t.Fatalf("%d fetches", n)
	}
	// A kid still unknown after the rotation does not refetch within a minute.
	other := oidctest.Mint(t, map[string]any{"kid": "rotated-away"}, f.appleClaims())
	f.clock.Advance(RefetchInterval - time.Second)
	if _, err := f.verifier.Verify(ctx, "apple", other, binding); !errors.Is(err, ErrInvalid) || len(f.transport.Requests()) != 2 {
		t.Fatal(err, len(f.transport.Requests()))
	}
	f.clock.Advance(time.Second)
	if _, err := f.verifier.Verify(ctx, "apple", other, binding); !errors.Is(err, ErrInvalid) || len(f.transport.Requests()) != 3 {
		t.Fatal(err, len(f.transport.Requests()))
	}
}

func TestJWKSFailures(t *testing.T) {
	big := append([]byte(`{"keys":[],"pad":"`), bytes.Repeat([]byte("x"), MaxJWKSBytes)...)
	big = append(big, []byte(`"}`)...)
	for name, set := range map[string]func(*oidctest.Transport){
		"over 64 KiB":  func(tr *oidctest.Transport) { tr.Body = big },
		"status 500":   func(tr *oidctest.Transport) { tr.Status = 500 },
		"not json":     func(tr *oidctest.Transport) { tr.Body = []byte("<html>") },
		"keys missing": func(tr *oidctest.Transport) { tr.Body = []byte(`{}`) },
	} {
		f := newFixture(t, nil)
		set(f.transport)
		if _, err := f.verifier.Verify(ctx, "apple", oidctest.Mint(t, nil, f.appleClaims()), binding); !errors.Is(err, ErrUnavailable) {
			t.Errorf("%s: %v", name, err)
		}
		// A failed fetch is retried at most once a minute.
		_, _ = f.verifier.Verify(ctx, "apple", oidctest.Mint(t, nil, f.appleClaims()), binding)
		if n := len(f.transport.Requests()); n != 1 {
			t.Errorf("%s: %d fetches", name, n)
		}
	}
	// Exactly 64 KiB is accepted.
	f := newFixture(t, nil)
	body := oidctest.JWKS(t)
	padded := append(bytes.TrimRight(body, "}\n "), []byte(`,"pad":"`)...)
	padded = append(padded, bytes.Repeat([]byte("x"), MaxJWKSBytes-len(padded)-2)...)
	padded = append(padded, []byte(`"}`)...)
	if len(padded) != MaxJWKSBytes {
		t.Fatal(len(padded))
	}
	f.transport.Body = padded
	if _, err := f.verifier.Verify(ctx, "apple", oidctest.Mint(t, nil, f.appleClaims()), binding); err != nil {
		t.Fatal(err)
	}
}

// Unusable keys in a JWKS are skipped: wrong kty, alg or use, short moduli.
func TestParseJWKS(t *testing.T) {
	good := oidctest.JWKS(t)
	keys, err := parseJWKS(good)
	if err != nil || len(keys) != 1 || keys[oidctest.KID] == nil || keys[oidctest.KID].N.BitLen() != 2048 {
		t.Fatal(keys, err)
	}
	for name, body := range map[string]string{
		"ec key":     `{"keys":[{"kty":"EC","kid":"a","crv":"P-256","x":"AA","y":"AA"}]}`,
		"alg RS384":  strings.Replace(string(good), `"RS256"`, `"RS384"`, 1),
		"use enc":    strings.Replace(string(good), `"sig"`, `"enc"`, 1),
		"short n":    `{"keys":[{"kty":"RSA","kid":"a","n":"AQAB","e":"AQAB"}]}`,
		"even e":     strings.Replace(string(good), `"AQAB"`, `"AQAA"`, 1),
		"n not b64":  `{"keys":[{"kty":"RSA","kid":"a","n":"***","e":"AQAB"}]}`,
		"empty kid":  strings.Replace(string(good), `"localflow-test-1"`, `""`, 1),
		"huge e":     strings.Replace(string(good), `"AQAB"`, `"AQAAAAAAAAAB"`, 1),
		"e missing":  strings.Replace(string(good), `"e": "AQAB",`, ``, 1),
		"n missing ": `{"keys":[{"kty":"RSA","kid":"a","e":"AQAB"}]}`,
	} {
		keys, err := parseJWKS([]byte(body))
		if err != nil || len(keys) != 0 {
			t.Errorf("%s: %v %v", name, keys, err)
		}
	}
}

func TestIdentityStringHidesClaims(t *testing.T) {
	identity := Identity{Provider: "apple", Subject: "001234.abcdef", Display: "oliver@example.com"}
	for _, s := range []string{identity.String(), identity.GoString()} {
		if strings.Contains(s, "001234") || strings.Contains(s, "oliver") {
			t.Fatal(s)
		}
	}
}

func TestNewValidatesConfig(t *testing.T) {
	if _, err := New(Config{}); err == nil {
		t.Fatal("no Apple audience")
	}
	if _, err := New(Config{AppleAudiences: []string{""}}); err == nil {
		t.Fatal("empty Apple audience")
	}
	if _, err := New(Config{AppleAudiences: []string{"a"}, GoogleClientIDs: []string{""}}); err == nil {
		t.Fatal("empty Google client ID")
	}
	if _, err := New(Config{AppleAudiences: []string{"a"}, Now: nil}); err != nil {
		t.Fatal("defaults", err)
	}
}
