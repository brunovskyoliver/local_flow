package dashboard

import (
	"context"
	"encoding/json"
	"localflow/server/internal/usage"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const installation = "11111111-1111-4111-8111-111111111111"
const credential = "fixture-credential-at-least-thirty-two-bytes"

func fixture(t *testing.T) *Projection {
	t.Helper()
	p, e := Open(filepath.Join(t.TempDir(), "dashboard.sqlite"), func() time.Time { return time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC) })
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { p.Close() })
	return p
}
func batch() usage.Batch {
	return usage.Batch{Installation: installation, Control: usage.Control{UserID: "22222222-2222-4222-8222-222222222222", DeviceID: "33333333-3333-4333-8333-333333333333", Epoch: 1, Revision: 1, Enabled: true, Grant: "44444444-4444-4444-8444-444444444444"}, Rows: []usage.Row{{Day: "2026-10-23", Revision: 1, LocalCount: 1, LocalAudioMS: 1000, Coverage: "complete"}}}
}
func TestDelayedExportCannotResurrectDeletedEpoch(t *testing.T) {
	p := fixture(t)
	b := batch()
	if e := p.Apply(context.Background(), b); e != nil {
		t.Fatal(e)
	}
	if e := p.Apply(context.Background(), b); e != nil {
		t.Fatal(e)
	}
	c := b
	c.Rows = nil
	c.Control.Epoch = 2
	c.Control.Revision = 2
	c.Control.DeletionCutoff = 1
	c.Control.Enabled = false
	c.Control.Grant = ""
	if e := p.Apply(context.Background(), c); e != nil {
		t.Fatal(e)
	}
	if e := p.Apply(context.Background(), b); e != usage.ErrRevoked {
		t.Fatal(e)
	}
	rows, e := p.Rows(context.Background())
	if e != nil || len(rows) != 0 {
		t.Fatal(rows, e)
	}
}
func TestConcurrentControlAndDataFinishDeleted(t *testing.T) {
	for i := 0; i < 12; i++ {
		p := fixture(t)
		b := batch()
		c := b
		c.Rows = nil
		c.Control.Epoch = 2
		c.Control.Revision = 2
		c.Control.DeletionCutoff = 1
		c.Control.Enabled = false
		c.Control.Grant = ""
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); _ = p.Apply(context.Background(), b) }()
		go func() {
			defer wg.Done()
			if e := p.Apply(context.Background(), c); e != nil {
				t.Error(e)
			}
		}()
		wg.Wait()
		rows, e := p.Rows(context.Background())
		if e != nil || len(rows) != 0 {
			t.Fatal(rows, e)
		}
	}
}
func handler(t *testing.T, p *Projection) *Handler {
	t.Helper()
	h, e := New(p, Config{BaseURL: "https://dashboard.example", OwnerIssuer: "https://accounts.google.com", OwnerSubject: "owner", ClientID: "client", ClientSecret: "secret", Installation: installation, IngestCredential: credential})
	if e != nil {
		t.Fatal(e)
	}
	return h
}
func TestTLSExportDuplicateWithdrawalDeletion(t *testing.T) {
	p := fixture(t)
	h := handler(t, p)
	srv := httptest.NewTLSServer(h)
	defer srv.Close()
	s, e := usage.Open(filepath.Join(t.TempDir(), "usage.sqlite"), usage.Config{Approved: func(usage.Identity) bool { return true }, Now: func() time.Time { return time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC) }})
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	id := usage.Identity{User: 1, Device: 1}
	g, e := s.Handle(context.Background(), id, usage.Request{Version: 1, Action: "enable"})
	if e != nil {
		t.Fatal(e)
	}
	u, _ := url.Parse(srv.URL)
	ex, e := usage.NewExporter(s, usage.ExportConfig{Endpoint: srv.URL + "/v1/ingest/usage", AllowedHost: u.Host, Installation: installation, Credential: credential, Client: srv.Client()})
	if e != nil {
		t.Fatal(e)
	}
	if e = ex.Once(context.Background()); e != nil {
		t.Fatal(e)
	}
	req := usage.Request{Version: 1, Action: "snapshot", Epoch: g.Epoch, Grant: g.Grant, Rows: batch().Rows}
	if _, e = s.Handle(context.Background(), id, req); e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 2; i++ {
		if e = ex.Once(context.Background()); e != nil {
			t.Fatal(e)
		}
	}
	rows, e := p.Rows(context.Background())
	if e != nil || len(rows) != 1 || rows[0].Local != 1 {
		t.Fatal(rows, e)
	}
	del, e := s.Handle(context.Background(), id, usage.Request{Version: 1, Action: "delete_user", Epoch: g.Epoch, Grant: g.Grant})
	if e != nil || !del.PropagationPending {
		t.Fatal(del, e)
	}
	if e = ex.Once(context.Background()); e != nil {
		t.Fatal(e)
	}
	status, e := s.Handle(context.Background(), id, usage.Request{Version: 1, Action: "status"})
	if e != nil || status.PropagationPending {
		t.Fatal(status, e)
	}
	rows, e = p.Rows(context.Background())
	if e != nil || len(rows) != 0 {
		t.Fatal(rows, e)
	}
}
func TestAuthorizationBodyLimitsAndTemplateEscaping(t *testing.T) {
	p := fixture(t)
	h := handler(t, p)
	for _, path := range []string{"/", "/v1/ingest/usage"} {
		r := httptest.NewRequest("GET", path, nil)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if path == "/" && w.Code != 303 || path != "/" && w.Code != 405 {
			t.Fatal(path, w.Code)
		}
	}
	b := batch()
	data, _ := json.Marshal(b)
	r := httptest.NewRequest("POST", "/v1/ingest/usage", strings.NewReader(string(data)))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal(w.Code)
	}
	r = httptest.NewRequest("POST", "/v1/ingest/usage", strings.NewReader(strings.Repeat("x", usage.MaxBody+1)))
	r.Header.Set("Authorization", "Bearer "+credential)
	r.Header.Set("X-LocalFlow-Installation", installation)
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 400 {
		t.Fatal(w.Code)
	}
	b.Directory = &usage.Directory{Label: "<script>private marker</script>", Revision: 1}
	if e := p.Apply(context.Background(), b); e != nil {
		t.Fatal(e)
	}
	h.sessions["fixture"] = session{time.Now().Add(time.Hour), "csrf"}
	r = httptest.NewRequest("GET", "/", nil)
	r.AddCookie(&http.Cookie{Name: "__Host-localflow", Value: "fixture"})
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 || strings.Contains(w.Body.String(), "<script>private marker") {
		t.Fatal("template injection", w.Code)
	}
	r = httptest.NewRequest("POST", "/logout", strings.NewReader("csrf=wrong"))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r.AddCookie(&http.Cookie{Name: "__Host-localflow", Value: "fixture"})
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal(w.Code)
	}
}

func TestOwnerDeletionControlAndUserDayTotals(t *testing.T) {
	p := fixture(t)
	b := batch()
	if err := p.Apply(context.Background(), b); err != nil {
		t.Fatal(err)
	}
	b.Control.DeviceID = "55555555-5555-4555-8555-555555555555"
	b.Rows[0].RemoteCount = 2
	if err := p.Apply(context.Background(), b); err != nil {
		t.Fatal(err)
	}
	rows, e := p.Rows(context.Background())
	if e != nil || len(rows) != 1 || rows[0].Local != 2 || rows[0].Remote != 2 || rows[0].Duration() != "2s" {
		t.Fatal(rows, e)
	}
	if e = p.RequestDeletion(context.Background(), installation, b.Control.UserID); e != nil {
		t.Fatal(e)
	}
	rows, e = p.Rows(context.Background())
	if e != nil || !rows[0].DeletionPending {
		t.Fatal(rows, e)
	}
	h := handler(t, p)
	r := httptest.NewRequest("GET", "/v1/control/deletions", nil)
	r.Header.Set("Authorization", "Bearer "+credential)
	r.Header.Set("X-LocalFlow-Installation", installation)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 || !strings.Contains(w.Body.String(), b.Control.UserID) {
		t.Fatal(w.Code, w.Body.String())
	}
}

func TestPaginationAndTotalOverflow(t *testing.T) {
	p := fixture(t)
	b := batch()
	for day := 1; day <= 3; day++ {
		b.Rows[0].Day = time.Date(2026, 10, day, 0, 0, 0, 0, time.UTC).Format("2006-01-02")
		if e := p.Apply(context.Background(), b); e != nil {
			t.Fatal(e)
		}
	}
	rows, e := p.RowsPage(context.Background(), 1, 1)
	if e != nil || len(rows) != 1 || rows[0].Day != "2026-10-02" {
		t.Fatal(rows, e)
	}
	b.Rows[0].Revision = 2
	b.Rows[0].LocalCount = 9223372036854775807
	if e := p.Apply(context.Background(), b); e != nil {
		t.Fatal(e)
	}
	b.Control.DeviceID = "55555555-5555-4555-8555-555555555555"
	b.Rows[0].LocalCount = 1
	if e := p.Apply(context.Background(), b); e != usage.ErrInvalid {
		t.Fatal("overflow accepted", e)
	}
}
