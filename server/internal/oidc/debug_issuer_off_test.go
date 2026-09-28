//go:build !localflow_debug

package oidc

import "testing"

// Normal builds refuse a test issuer.
func TestTestIssuerNeedsDebugBuild(t *testing.T) {
	if DebugBuild {
		t.Fatal("DebugBuild set without the tag")
	}
	if _, err := New(Config{AppleAudiences: []string{"a"}, TestIssuer: "https://i", TestJWKS: "/x"}); err == nil {
		t.Fatal("test issuer accepted in a normal build")
	}
}
