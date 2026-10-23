package dashboard

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"html/template"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"localflow/server/internal/oidc"
	"localflow/server/internal/usage"
)

//go:embed templates/*.html
var files embed.FS
var page = template.Must(template.New("usage.html").ParseFS(files, "templates/*.html"))

type Verifier interface {
	Verify(context.Context, string, string, []byte) (oidc.Identity, error)
}
type Config struct {
	BaseURL, OwnerIssuer, OwnerSubject, ClientID, ClientSecret, Installation, IngestCredential string
	Verifier                                                                                   Verifier
	HTTPClient                                                                                 *http.Client
	Now                                                                                        func() time.Time
}
type session struct {
	expires time.Time
	csrf    string
}
type login struct {
	expires  time.Time
	verifier string
	nonce    []byte
}
type Handler struct {
	projection *Projection
	cfg        Config
	mu         sync.Mutex
	sessions   map[string]session
	logins     map[string]login
	slots      chan struct{}
}

func New(p *Projection, cfg Config) (*Handler, error) {
	u, err := url.Parse(cfg.BaseURL)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.User != nil || cfg.OwnerIssuer != "https://accounts.google.com" || cfg.OwnerSubject == "" || len(cfg.OwnerSubject) > 255 || cfg.ClientID == "" || cfg.ClientSecret == "" || len(cfg.IngestCredential) < 32 || len(cfg.IngestCredential) > 512 {
		return nil, errors.New("dashboard: invalid configuration")
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	if cfg.Verifier == nil {
		cfg.Verifier, err = oidc.New(oidc.Config{AppleAudiences: []string{cfg.ClientID}, GoogleClientIDs: []string{cfg.ClientID}, Now: cfg.Now})
		if err != nil {
			return nil, err
		}
	}
	return &Handler{projection: p, cfg: cfg, sessions: map[string]session{}, logins: map[string]login{}, slots: make(chan struct{}, 4)}, nil
}
func token() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("dashboard: entropy unavailable")
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
	select {
	case h.slots <- struct{}{}:
		defer func() { <-h.slots }()
	default:
		http.Error(w, "Busy", 503)
		return
	}
	switch r.URL.Path {
	case "/v1/control/deletions":
		h.deletionRequests(w, r)
	case "/v1/ingest/usage":
		h.ingest(w, r)
	case "/login":
		if r.Method != http.MethodGet {
			http.Error(w, "Method not allowed", 405)
			return
		}
		h.begin(w, r)
	case "/callback":
		if r.Method != http.MethodGet {
			http.Error(w, "Method not allowed", 405)
			return
		}
		h.callback(w, r)
	case "/", "/logout", "/delete":
		sess, ok := h.authenticate(r)
		if !ok {
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		if r.URL.Path == "/delete" {
			h.deleteUsage(w, r, sess)
			return
		}
		if r.URL.Path == "/logout" {
			if r.Method != http.MethodPost {
				http.Error(w, "Method not allowed", 405)
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, 4096)
			if r.ParseForm() != nil || subtle.ConstantTimeCompare([]byte(r.FormValue("csrf")), []byte(sess.csrf)) != 1 {
				http.Error(w, "Forbidden", 403)
				return
			}
			c, _ := r.Cookie("__Host-localflow")
			h.mu.Lock()
			delete(h.sessions, c.Value)
			h.mu.Unlock()
			http.SetCookie(w, &http.Cookie{Name: "__Host-localflow", Value: "", Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: -1})
			http.Redirect(w, r, "/login", 303)
			return
		}
		if r.Method != http.MethodGet {
			http.Error(w, "Method not allowed", 405)
			return
		}
		offset := 0
		if raw := r.URL.Query().Get("offset"); raw != "" {
			n, e := strconv.Atoi(raw)
			if e != nil || n < 0 || n > 8900 || n%100 != 0 {
				http.Error(w, "Invalid page", 400)
				return
			}
			offset = n
		}
		rows, err := h.projection.RowsPage(r.Context(), offset, 101)
		if err != nil {
			http.Error(w, "Reporting unavailable", 503)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_ = page.Execute(w, struct {
			Rows        []ViewRow
			CSRF        string
			Previous    int
			Next        int
			HasPrevious bool
			HasNext     bool
		}{rows[:min(len(rows), 100)], sess.csrf, max(offset-100, 0), offset + 100, offset > 0, len(rows) > 100})
	default:
		http.NotFound(w, r)
	}
}
func (h *Handler) ingest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", 405)
		return
	}
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+h.cfg.IngestCredential)) != 1 || r.Header.Get("X-LocalFlow-Installation") != h.cfg.Installation {
		http.Error(w, "Unauthorized", 401)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, usage.MaxBody)
	data, readErr := io.ReadAll(r.Body)
	b, decodeErr := usage.DecodeBatch(data)
	if readErr != nil || decodeErr != nil || b.Installation != h.cfg.Installation {
		http.Error(w, "Invalid report", 400)
		return
	}
	if err := h.projection.Apply(r.Context(), b); err != nil {
		code := 400
		if errors.Is(err, usage.ErrRevoked) {
			code = 409
		}
		if errors.Is(err, usage.ErrBusy) {
			code = 503
		}
		http.Error(w, "Report refused", code)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
func (h *Handler) purgeLocked() {
	now := h.cfg.Now()
	for k, v := range h.sessions {
		if !now.Before(v.expires) {
			delete(h.sessions, k)
		}
	}
	for k, v := range h.logins {
		if !now.Before(v.expires) {
			delete(h.logins, k)
		}
	}
}
func (h *Handler) authenticate(r *http.Request) (session, bool) {
	c, err := r.Cookie("__Host-localflow")
	if err != nil {
		return session{}, false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.purgeLocked()
	s, ok := h.sessions[c.Value]
	return s, ok
}
func (h *Handler) begin(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	h.purgeLocked()
	if len(h.logins) >= 10 {
		h.mu.Unlock()
		http.Error(w, "Login busy", 503)
		return
	}
	state := token()
	verifier := token()
	nonce := make([]byte, 32)
	_, _ = rand.Read(nonce)
	h.logins[state] = login{h.cfg.Now().Add(5 * time.Minute), verifier, nonce}
	h.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "__Host-localflow-login", Value: state, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: 300})
	hash := sha256.Sum256([]byte(verifier))
	q := url.Values{"client_id": {h.cfg.ClientID}, "redirect_uri": {h.cfg.BaseURL + "/callback"}, "response_type": {"code"}, "scope": {"openid email"}, "state": {state}, "nonce": {base64.RawURLEncoding.EncodeToString(nonce)}, "code_challenge": {base64.RawURLEncoding.EncodeToString(hash[:])}, "code_challenge_method": {"S256"}}
	http.Redirect(w, r, "https://accounts.google.com/o/oauth2/v2/auth?"+q.Encode(), 302)
}
func (h *Handler) callback(w http.ResponseWriter, r *http.Request) {
	c, err := r.Cookie("__Host-localflow-login")
	state := r.URL.Query().Get("state")
	if err != nil || state == "" || len(state) > 128 || subtle.ConstantTimeCompare([]byte(c.Value), []byte(state)) != 1 {
		http.Error(w, "Login refused", 403)
		return
	}
	h.mu.Lock()
	h.purgeLocked()
	flow, ok := h.logins[state]
	delete(h.logins, state)
	h.mu.Unlock()
	if !ok {
		http.Error(w, "Login expired", 403)
		return
	}
	code := r.URL.Query().Get("code")
	if code == "" || len(code) > 8192 {
		http.Error(w, "Login refused", 403)
		return
	}
	form := url.Values{"client_id": {h.cfg.ClientID}, "client_secret": {h.cfg.ClientSecret}, "code": {code}, "code_verifier": {flow.verifier}, "grant_type": {"authorization_code"}, "redirect_uri": {h.cfg.BaseURL + "/callback"}}
	req, _ := http.NewRequestWithContext(r.Context(), http.MethodPost, "https://oauth2.googleapis.com/token", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := h.cfg.HTTPClient.Do(req)
	if err != nil {
		http.Error(w, "Login unavailable", 503)
		return
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, usage.MaxBody+1))
	if err != nil || len(data) > usage.MaxBody || res.StatusCode != 200 {
		http.Error(w, "Login refused", 403)
		return
	}
	var result struct {
		IDToken string `json:"id_token"`
	}
	if json.Unmarshal(data, &result) != nil {
		http.Error(w, "Login refused", 403)
		return
	}
	identity, err := h.cfg.Verifier.Verify(r.Context(), "google", result.IDToken, flow.nonce)
	// The reused verifier accepts Google's legacy issuer spelling. The owner
	// allowlist deliberately requires the exact configured issuer as well.
	parts := strings.Split(result.IDToken, ".")
	issuer := ""
	if len(parts) == 3 {
		payload, e := base64.RawURLEncoding.DecodeString(parts[1])
		if e == nil {
			var claims struct {
				Issuer string `json:"iss"`
			}
			if json.NewDecoder(bytes.NewReader(payload)).Decode(&claims) == nil {
				issuer = claims.Issuer
			}
		}
	}
	if err != nil || identity.Subject != h.cfg.OwnerSubject || issuer != h.cfg.OwnerIssuer {
		http.Error(w, "Owner access only", 403)
		return
	}
	h.mu.Lock()
	h.purgeLocked()
	if len(h.sessions) >= 10 {
		h.mu.Unlock()
		http.Error(w, "Session limit reached", 503)
		return
	}
	id := token()
	h.sessions[id] = session{h.cfg.Now().Add(8 * time.Hour), token()}
	h.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "__Host-localflow", Value: id, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: 28800})
	http.SetCookie(w, &http.Cookie{Name: "__Host-localflow-login", Value: "", Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: -1})
	http.Redirect(w, r, "/", 303)
}
