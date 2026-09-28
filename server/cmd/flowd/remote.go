package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"localflow/server/internal/accounts"
	"localflow/server/internal/remote"
	"localflow/server/internal/rewrite"
)

// remoteConfig holds the remote serving flags (contracts/flowd-cli.md).
// Remote serving is off when listen is empty.
type remoteConfig struct {
	listen          string
	dataDir         string
	speechWorker    string
	speechModels    string
	appleAudience   []string
	googleClientIDs []string
	dev             bool
	// Debug builds only (-tags localflow_debug).
	testIssuer string
	testJWKS   string
	debugBusy  bool
	// rewrite is the main listener's rewrite handler, set by run: the
	// channel's rewrite operation shares its in-flight limit and analysis
	// gate (Feature 014 T070). Not a flag.
	rewrite *rewrite.Handler
}

// validate checks the remote flags that need no file system or Keychain
// access; privacy and the identity key are checked at start.
func (r *remoteConfig) validate(mainListen string, appleAudience, googleClientIDs string) error {
	var err error
	if r.appleAudience, err = splitList(appleAudience, false); err != nil {
		return errors.New("--apple-audience must be a comma-separated list of audiences")
	}
	if r.googleClientIDs, err = splitList(googleClientIDs, true); err != nil {
		return errors.New("--google-client-id must be a comma-separated list of client IDs")
	}
	if r.listen == "" {
		return nil
	}
	host, _, err := net.SplitHostPort(r.listen)
	if ip := net.ParseIP(host); err != nil || ip == nil || !ip.IsLoopback() {
		return errors.New("--remote-listen must be a loopback IP literal host:port")
	}
	if r.listen == mainListen {
		return errors.New("--remote-listen must differ from --listen")
	}
	if r.dataDir == "" || !filepath.IsAbs(r.dataDir) {
		return errors.New("--data-dir must be an absolute path when --remote-listen is set")
	}
	r.dataDir = filepath.Clean(r.dataDir)
	if r.speechModels == "" {
		r.speechModels = filepath.Join(r.dataDir, "Models")
	}
	if r.speechWorker == "" {
		executable, err := os.Executable()
		if err != nil {
			return errors.New("cannot locate flowd; pass --speech-worker")
		}
		r.speechWorker = filepath.Join(filepath.Dir(executable), "flowd-speech")
	}
	return nil
}

func splitList(list string, emptyAllowed bool) ([]string, error) {
	if list == "" {
		if emptyAllowed {
			return nil, nil
		}
		return nil, errors.New("empty list")
	}
	var out []string
	for _, item := range strings.Split(list, ",") {
		if item == "" || len(out) >= 16 {
			return nil, errors.New("invalid list")
		}
		out = append(out, item)
	}
	return out, nil
}

// privateDirectory requires dir to be a directory owned by the running user
// with mode 0700.
func privateDirectory(dir string) error {
	info, err := os.Stat(dir)
	if err != nil {
		return errors.New("--data-dir does not exist; run flowd admin init")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || !ok || int(stat.Uid) != os.Getuid() || info.Mode().Perm() != 0o700 {
		return errors.New("--data-dir must be a directory private to this user (owned by it, mode 0700)")
	}
	return nil
}

// remoteServer is the running remote listener and what it owns.
type remoteServer struct {
	server   *http.Server
	listener *remote.Listener
	net      net.Listener
	store    *accounts.Store
	watcher  *accounts.Watcher
	stop     context.CancelFunc
	polling  chan struct{}
	// stopOperations releases what the operations own (the speech worker).
	stopOperations func()
}

// startRemote refuses to start unless the data directory is private and the
// identity key exists, then opens the store, the snapshot watcher and the
// loopback listener. Admin changes reach live channels through the watcher.
func startRemote(ctx context.Context, r remoteConfig, logger *log.Logger) (*remoteServer, error) {
	if err := privateDirectory(r.dataDir); err != nil {
		return nil, err
	}
	service := accounts.ServiceProduction
	if r.dev {
		service = accounts.ServiceDevelopment
	}
	identity, err := accounts.Keychain{Runner: keychainRunner, Service: service}.Load(ctx, r.dataDir)
	if err != nil {
		return nil, err
	}
	store, err := accounts.Open(r.dataDir, time.Now)
	if err != nil {
		return nil, err
	}
	s := &remoteServer{store: store}
	s.watcher, err = store.Watch(ctx, func(lost accounts.Lost) {
		logger.Printf("remote event=approval_lost users=%d devices=%d", len(lost.Users), len(lost.Devices))
		s.listener.Revoke(lost)
	})
	if err != nil {
		store.Close()
		return nil, err
	}
	operations, stopOperations, err := remoteOperations(ctx, r, store, s.watcher, logger)
	if err != nil {
		s.watcher.Close()
		store.Close()
		return nil, err
	}
	s.stopOperations = stopOperations
	s.listener = remote.NewListener(remote.Config{
		Identity: identity, Accounts: s.watcher, ServerVersion: rewrite.ServerVersion, Logger: logger,
		Operations: operations,
		// cross_user_attempt rows (Feature 014 T085); content-free.
		Audit: func(entry accounts.AuditEntry) {
			if err := store.Audit(context.Background(), entry); err != nil {
				logger.Printf("remote event=audit_failed action=%s", entry.Action)
			}
		},
	})
	s.net, err = remote.Listen(r.listen)
	if err != nil {
		s.watcher.Close()
		store.Close()
		return nil, fmt.Errorf("could not open remote listener: %w", err)
	}
	watchCtx, stop := context.WithCancel(ctx)
	s.stop, s.polling = stop, make(chan struct{})
	ticker := time.NewTicker(accounts.PollInterval)
	go func() {
		defer close(s.polling)
		defer ticker.Stop()
		s.watcher.Run(watchCtx, ticker.C)
	}()
	s.server = &http.Server{Handler: s.listener, ReadHeaderTimeout: 5 * time.Second, MaxHeaderBytes: 16384,
		BaseContext: func(net.Listener) context.Context { return ctx }}
	logger.Printf("remote listening=%s", s.net.Addr())
	return s, nil
}

// shutdown closes every channel, then the listener, watcher and store.
func (s *remoteServer) shutdown(ctx context.Context) {
	s.listener.CloseAll()
	if err := s.server.Shutdown(ctx); err != nil {
		_ = s.server.Close()
	}
	s.stop()
	<-s.polling
	if s.stopOperations != nil {
		s.stopOperations()
	}
	s.watcher.Close()
	s.store.Close()
}

// remoteOperations merges the operations of each hello purpose: enrollment and
// refresh (remote_ops_accounts.go) and the session channel's dictation and rewrite
// (remote_ops_session.go). The returned stop function releases what they own.
func remoteOperations(ctx context.Context, r remoteConfig, store *accounts.Store,
	watcher *accounts.Watcher, logger *log.Logger) (remote.Operations, func(), error) {
	operations := remote.Operations{}
	accountOps, err := accountOperations(r, store, watcher, logger)
	if err != nil {
		return nil, nil, err
	}
	for purpose, starts := range accountOps {
		operations[purpose] = starts
	}
	session, stop, err := sessionOperations(ctx, r, store, watcher, logger)
	if err != nil {
		return nil, nil, err
	}
	if len(session) > 0 {
		operations[remote.PurposeSession] = session
	}
	return operations, stop, nil
}
