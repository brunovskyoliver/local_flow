//go:build localflow_debug

package oidc

import (
	"errors"
	"os"
)

// DebugBuild reports whether --test-issuer and --test-jwks are available.
const DebugBuild = true

// testIssuerKeys loads the local issuer's JWKS file (for example
// fixtures/remote/test-jwks.json) for integration tests without Apple or
// Google. Debug builds only.
func testIssuerKeys(issuer, path string) (keySource, error) {
	if issuer == "" || path == "" {
		return nil, errors.New("oidc: --test-issuer and --test-jwks go together")
	}
	body, err := os.ReadFile(path)
	if err != nil || len(body) > MaxJWKSBytes {
		return nil, errors.New("oidc: cannot read --test-jwks")
	}
	keys, err := parseJWKS(body)
	if err != nil || len(keys) == 0 {
		return nil, errors.New("oidc: --test-jwks holds no RS256 key")
	}
	return staticKeys(keys), nil
}
