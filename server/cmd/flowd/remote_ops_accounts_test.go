package main

import (
	"context"
	"io"
	"log"
	"testing"
	"time"

	"localflow/server/internal/accounts"
	"localflow/server/internal/oidc"
	"localflow/server/internal/oidc/oidctest"
	"localflow/server/internal/remote"
)

// flowd serves enroll and refresh with a verifier built from the flags; a
// test issuer is honoured only in debug builds.
func TestAccountOperations(t *testing.T) {
	store, err := accounts.Open(t.TempDir(), time.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	watcher, err := store.Watch(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer watcher.Close()
	logger := log.New(io.Discard, "", 0)
	ops, err := accountOperations(remoteConfig{appleAudience: []string{"org.localflow.LocalFlow"}}, store, watcher, logger)
	if err != nil || ops[remote.PurposeEnroll]["enroll"] == nil || ops[remote.PurposeRefresh]["refresh"] == nil {
		t.Fatal(ops, err)
	}
	if _, err := accountOperations(remoteConfig{}, store, watcher, logger); err == nil {
		t.Fatal("no Apple audience accepted")
	}
	withIssuer := remoteConfig{appleAudience: []string{"a"}, testIssuer: "https://issuer.localflow.test",
		testJWKS: oidctest.FixturePath("test-jwks.json")}
	if _, err := accountOperations(withIssuer, store, watcher, logger); (err == nil) != oidc.DebugBuild {
		t.Fatalf("test issuer in a debug build %v: %v", oidc.DebugBuild, err)
	}
	withIssuer.testJWKS = "/nonexistent/jwks.json"
	if _, err := accountOperations(withIssuer, store, watcher, logger); err == nil {
		t.Fatal("unreadable --test-jwks accepted")
	}
}
