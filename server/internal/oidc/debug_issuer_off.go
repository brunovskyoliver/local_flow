//go:build !localflow_debug

package oidc

import "errors"

// DebugBuild reports whether --test-issuer and --test-jwks are available.
const DebugBuild = false

func testIssuerKeys(string, string) (keySource, error) {
	return nil, errors.New("oidc: a test issuer requires a build with -tags localflow_debug")
}
