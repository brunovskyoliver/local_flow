package main

import (
	"context"
	"log"
	"time"

	"localflow/server/internal/accounts"
	"localflow/server/internal/oidc"
	"localflow/server/internal/remote"
)

// accountOperations returns the enroll and refresh operations (User Story 2)
// with an ID token verifier built from --apple-audience and
// --google-client-id, or, in debug builds, --test-issuer and --test-jwks.
func accountOperations(r remoteConfig, store *accounts.Store, watcher *accounts.Watcher,
	logger *log.Logger) (remote.Operations, error) {
	verifier, err := oidc.New(oidc.Config{
		AppleAudiences:  r.appleAudience,
		GoogleClientIDs: r.googleClientIDs,
		Now:             time.Now,
		TestIssuer:      r.testIssuer,
		TestJWKS:        r.testJWKS,
	})
	if err != nil {
		return nil, err
	}
	return remote.AccountOperations(remote.AccountsConfig{
		Store:    store,
		Verifier: verifier,
		Reload: func(ctx context.Context) error {
			_, err := watcher.Poll(ctx)
			return err
		},
		Logger: logger,
	}), nil
}
