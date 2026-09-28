//go:build localflow_debug

package oidc

import (
	"errors"
	"testing"

	"localflow/server/internal/oidc/oidctest"
)

// --test-issuer replaces both providers' issuers and key sources with a local
// issuer and JWKS file; audiences, nonces and email_verified still apply, and
// nothing is fetched.
func TestDebugIssuer(t *testing.T) {
	f := newFixture(t, []string{"client-1.apps.googleusercontent.com"})
	verifier, err := New(Config{
		AppleAudiences:  []string{"org.localflow.LocalFlow"},
		GoogleClientIDs: []string{"client-1.apps.googleusercontent.com"},
		HTTPClient:      f.transport.Client(),
		Now:             f.clock.Now,
		TestIssuer:      "https://issuer.localflow.test",
		TestJWKS:        oidctest.FixturePath("test-jwks.json"),
	})
	if err != nil {
		t.Fatal(err)
	}
	apple := with(f.appleClaims(), map[string]any{"iss": "https://issuer.localflow.test"})
	if identity, err := verifier.Verify(ctx, "apple", oidctest.Mint(t, nil, apple), binding); err != nil || identity.Provider != "apple" {
		t.Fatal(identity, err)
	}
	google := with(f.googleClaims(), map[string]any{"iss": "https://issuer.localflow.test"})
	if _, err := verifier.Verify(ctx, "google", oidctest.Mint(t, nil, google), binding); err != nil {
		t.Fatal(err)
	}
	if _, err := verifier.Verify(ctx, "apple", oidctest.Mint(t, nil, f.appleClaims()), binding); !errors.Is(err, ErrInvalid) {
		t.Fatal("the real issuer is not accepted in test mode", err)
	}
	if _, err := verifier.Verify(ctx, "apple", oidctest.Mint(t, nil, with(apple, map[string]any{"aud": "x"})), binding); !errors.Is(err, ErrInvalid) {
		t.Fatal("audience still checked", err)
	}
	if len(f.transport.Requests()) != 0 {
		t.Fatal("test issuer fetched keys")
	}
	for name, cfg := range map[string]Config{
		"jwks missing":    {AppleAudiences: []string{"a"}, TestIssuer: "https://issuer.localflow.test"},
		"issuer missing":  {AppleAudiences: []string{"a"}, TestJWKS: oidctest.FixturePath("test-jwks.json")},
		"jwks unreadable": {AppleAudiences: []string{"a"}, TestIssuer: "https://i", TestJWKS: "/nonexistent/jwks.json"},
		"jwks no keys":    {AppleAudiences: []string{"a"}, TestIssuer: "https://i", TestJWKS: oidctest.FixturePath("README.md")},
	} {
		if _, err := New(cfg); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}
