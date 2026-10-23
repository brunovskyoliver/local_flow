// flowdash is an optional owner-only reporting process, separate from flowd.
package main

import (
	"context"
	"flag"
	"fmt"
	"localflow/server/internal/dashboard"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func readSecret(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return "", fmt.Errorf("credential must be a private regular file")
	}
	if info.Size() > 512 {
		return "", fmt.Errorf("credential file too large")
	}
	b, err := os.ReadFile(path)
	return strings.TrimSpace(string(b)), err
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "flowdash:", err)
		os.Exit(1)
	}
}
func run() error {
	var cfg dashboard.Config
	var listen, db, cert, key, secret, ingest string
	flag.StringVar(&listen, "listen", "127.0.0.1:8094", "TLS reporting listener")
	flag.StringVar(&db, "database", "", "absolute reporting SQLite path")
	flag.StringVar(&cert, "tls-cert", "", "TLS certificate path")
	flag.StringVar(&key, "tls-key", "", "TLS private key path")
	flag.StringVar(&cfg.BaseURL, "base-url", "", "HTTPS public origin, without trailing slash")
	flag.StringVar(&cfg.OwnerIssuer, "owner-issuer", "https://accounts.google.com", "exact owner OIDC issuer")
	flag.StringVar(&cfg.OwnerSubject, "owner-subject", "", "exact owner OIDC subject")
	flag.StringVar(&cfg.ClientID, "google-client-id", "", "Google OAuth web client ID")
	flag.StringVar(&secret, "google-secret-file", "", "0600 OAuth web client secret file")
	flag.StringVar(&cfg.Installation, "installation-id", "", "source installation UUID")
	flag.StringVar(&ingest, "ingest-credential-file", "", "0600 source credential file")
	flag.Parse()
	if db == "" || cert == "" || key == "" {
		return fmt.Errorf("database and TLS certificate/key are required")
	}
	var err error
	cfg.ClientSecret, err = readSecret(secret)
	if err != nil {
		return err
	}
	cfg.IngestCredential, err = readSecret(ingest)
	if err != nil {
		return err
	}
	p, err := dashboard.Open(db, time.Now)
	if err != nil {
		return err
	}
	defer p.Close()
	h, err := dashboard.New(p, cfg)
	if err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	srv := &http.Server{Addr: listen, Handler: h, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
	go func() {
		ticker := time.NewTicker(time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				shutdown, done := context.WithTimeout(context.Background(), 5*time.Second)
				defer done()
				_ = srv.Shutdown(shutdown)
				return
			case <-ticker.C:
				_ = p.Purge(ctx)
			}
		}
	}()
	err = srv.ListenAndServeTLS(cert, key)
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}
