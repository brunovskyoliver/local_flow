package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"localflow/server/internal/backend"
	"localflow/server/internal/rewrite"
)

// The loopback admin API (ADR 0032) lets the LocalFlow Server app on the same
// Mac read live counters and switch the summaries backend without restarting
// flowd. It has its own listener (--admin-listen, a loopback IP literal), is
// never mounted on the main or remote listener, and every request needs the
// bearer token from <data-dir>/admin-token (0600, created on first start).
//
//   GET /v1/admin/status    version, start time, counters, summaries backend
//   PUT /v1/admin/analysis  {"backend":"http://127.0.0.1:8443/v1","model":"smart"}
//                           or {"backend":""} for the rewrite model

const adminTokenFile = "admin-token"

// adminToken reads the token file, creating it with a random token when it is
// missing. A file other users can read is refused.
func adminToken(dataDir string) (string, error) {
	path := filepath.Join(dataDir, adminTokenFile)
	if info, err := os.Stat(path); err == nil {
		if info.Mode().Perm()&0o077 != 0 {
			return "", errors.New(path + " must be private to this user (mode 0600)")
		}
		data, err := os.ReadFile(path)
		token := strings.TrimSpace(string(data))
		if err != nil || len(token) < 32 {
			return "", errors.New("cannot read " + path)
		}
		return token, nil
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", err
	}
	token := hex.EncodeToString(secret)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "", errors.New("cannot create " + path)
	}
	defer file.Close()
	if _, err := file.WriteString(token + "\n"); err != nil {
		return "", err
	}
	return token, nil
}

// requestCounters counts client requests by service from flowd's own
// content-free log lines (`remote <service> … code=<code>`), the same lines
// the app's Stats tab reads.
// ponytail: parses the log line instead of hooking each operation; hook the
// remote operations directly if a line format changes.
type requestCounters struct {
	mu       sync.Mutex
	services map[string]*serviceCount
}

type serviceCount struct {
	Requests int64 `json:"requests"`
	Failures int64 `json:"failures"`
}

var countedServices = []string{"dictation", "rewrite", "analysis", "meeting", "live"}

var okCodes = map[string]bool{"ok": true, "succeeded": true, "closed": true, "discarded": true, "cancelled": true}

func (c *requestCounters) Write(p []byte) (int, error) {
	line := string(p)
	for _, service := range countedServices {
		if !strings.Contains(line, " remote "+service+" ") {
			continue
		}
		i := strings.LastIndex(line, " code=")
		if i < 0 {
			break
		}
		code, _, _ := strings.Cut(strings.TrimSpace(line[i+len(" code="):]), " ")
		c.mu.Lock()
		if c.services == nil {
			c.services = map[string]*serviceCount{}
		}
		count := c.services[service]
		if count == nil {
			count = &serviceCount{}
			c.services[service] = count
		}
		count.Requests++
		if !okCodes[code] {
			count.Failures++
		}
		c.mu.Unlock()
		break
	}
	return len(p), nil
}

func (c *requestCounters) snapshot() map[string]serviceCount {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := map[string]serviceCount{}
	for _, service := range countedServices {
		if count := c.services[service]; count != nil {
			out[service] = *count
		} else {
			out[service] = serviceCount{}
		}
	}
	return out
}

// switchableAnalysis is the summaries backend: the rewrite model alone, or a
// primary OpenAI-compatible server with the rewrite model as fallback
// (backend.Fallback). The admin API swaps it while flowd runs.
type switchableAnalysis struct {
	local             *backend.OpenAI
	firstToken, total time.Duration
	guard             func(context.Context) (context.Context, func(), error)
	current           atomic.Pointer[backend.Fallback]
	mu                sync.Mutex // serialises set
	primaryURL, model string
}

// GuardLocal receives the analysis handler's rewrite-first gate; only calls
// that run on the rewrite model wait for dictation.
func (s *switchableAnalysis) GuardLocal(guard func(context.Context) (context.Context, func(), error)) {
	s.guard = guard
	if f := s.current.Load(); f != nil {
		f.GuardLocal(guard)
	}
}

func (s *switchableAnalysis) Probe(ctx context.Context) backend.Info {
	if f := s.current.Load(); f != nil {
		return f.Probe(ctx)
	}
	return s.local.Probe(ctx)
}

func (s *switchableAnalysis) Generate(ctx context.Context, in backend.Input) (backend.Completion, error) {
	if f := s.current.Load(); f != nil {
		return f.Generate(ctx, in)
	}
	if s.guard != nil {
		guarded, release, err := s.guard(ctx)
		if err != nil {
			return backend.Completion{}, err
		}
		defer release()
		ctx = guarded
	}
	return s.local.Generate(ctx, in)
}

func (s *switchableAnalysis) ClearCache(ctx context.Context) error { return s.local.ClearCache(ctx) }

// set makes cfg the primary; an empty BaseURL leaves only the rewrite model.
func (s *switchableAnalysis) set(cfg backend.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if cfg.BaseURL == "" {
		s.current.Store(nil)
		s.primaryURL, s.model = "", ""
		return nil
	}
	cfg.FirstTokenTimeout, cfg.Timeout = s.firstToken, s.total
	primary, err := backend.New(cfg)
	if err != nil {
		return err
	}
	f := &backend.Fallback{Primary: primary, Secondary: s.local}
	if s.guard != nil {
		f.GuardLocal(s.guard)
	}
	// ponytail: the previous primary is dropped, not closed, so in-flight calls finish.
	s.current.Store(f)
	s.primaryURL, s.model = cfg.BaseURL, cfg.Model
	return nil
}

func (s *switchableAnalysis) state() (string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.primaryURL, s.model
}

// loopbackURL accepts only http(s) URLs to a loopback IP or localhost, so the
// admin API cannot point flowd at another machine.
func loopbackURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil {
		return false
	}
	host := u.Hostname()
	ip := net.ParseIP(host)
	return host == "localhost" || (ip != nil && ip.IsLoopback())
}

type adminAPI struct {
	token    string
	dataDir  string
	started  time.Time
	counters *requestCounters
	analysis *switchableAnalysis
}

func (a *adminAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	auth := r.Header.Get("Authorization")
	if auth == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	supplied, expected := sha256.Sum256([]byte(auth)), sha256.Sum256([]byte("Bearer "+a.token))
	if subtle.ConstantTimeCompare(supplied[:], expected[:]) != 1 {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	switch {
	case r.URL.Path == "/v1/admin/status" && r.Method == http.MethodGet:
		a.writeStatus(w)
	case r.URL.Path == "/v1/admin/analysis" && r.Method == http.MethodPut:
		var body struct{ Backend, Model string }
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
			http.Error(w, "invalid body", http.StatusBadRequest)
			return
		}
		cfg := backend.Config{BaseURL: body.Backend, Model: body.Model}
		if body.Backend != "" {
			if !loopbackURL(body.Backend) || body.Model == "" || len(body.Model) > 128 {
				http.Error(w, "backend must be a loopback http(s) URL with a model", http.StatusBadRequest)
				return
			}
			// The same key file the installer passes with --analysis-backend-key-file.
			if key, err := os.ReadFile(filepath.Join(a.dataDir, "analysis-api-key")); err == nil {
				cfg.Token = strings.TrimSpace(string(key))
			}
		}
		if err := a.analysis.set(cfg); err != nil {
			http.Error(w, "invalid backend", http.StatusBadRequest)
			return
		}
		a.writeStatus(w)
	default:
		http.NotFound(w, r)
	}
}

func (a *adminAPI) writeStatus(w http.ResponseWriter) {
	backendURL, model := a.analysis.state()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"version":    rewrite.ServerVersion,
		"started_at": a.started.UTC().Format(time.RFC3339),
		"counters":   a.counters.snapshot(),
		"analysis":   map[string]string{"backend": backendURL, "model": model},
	})
}

// validateAdminListen requires a loopback IP literal distinct from the other listeners.
func validateAdminListen(admin, main, remote, dataDir string) error {
	if admin == "" {
		return nil
	}
	host, _, err := net.SplitHostPort(admin)
	if ip := net.ParseIP(host); err != nil || ip == nil || !ip.IsLoopback() {
		return errors.New("--admin-listen must be a loopback IP literal host:port")
	}
	if admin == main || admin == remote {
		return errors.New("--admin-listen must differ from --listen and --remote-listen")
	}
	if dataDir == "" || !filepath.IsAbs(dataDir) {
		return errors.New("--admin-listen needs an absolute --data-dir for its token file")
	}
	return nil
}
