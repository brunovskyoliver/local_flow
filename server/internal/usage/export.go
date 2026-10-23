package usage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type ExportConfig struct {
	Endpoint     string
	AllowedHost  string
	Installation string
	Credential   string
	Client       *http.Client
}
type Exporter struct {
	mu     sync.Mutex
	store  *Store
	cfg    ExportConfig
	client *http.Client
}

func NewExporter(s *Store, cfg ExportConfig) (*Exporter, error) {
	u, err := url.Parse(cfg.Endpoint)
	if err != nil || u.Scheme != "https" || u.Host != cfg.AllowedHost || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "/v1/ingest/usage" || !uuidPattern.MatchString(cfg.Installation) || len(cfg.Credential) < 32 || len(cfg.Credential) > 512 || strings.ContainsAny(cfg.Credential, "\r\n") {
		return nil, ErrInvalid
	}
	client := http.Client{Timeout: 30 * time.Second}
	if cfg.Client != nil {
		client = *cfg.Client
		client.Timeout = 30 * time.Second
	}
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &Exporter{store: s, cfg: cfg, client: &client}, nil
}
func (e *Exporter) Once(ctx context.Context) error {
	if !e.mu.TryLock() {
		return ErrBusy
	}
	defer e.mu.Unlock()
	if err := e.pollDeletion(ctx); err != nil {
		return err
	}
	if err := e.store.Reconcile(ctx); err != nil {
		return err
	}
	batches, err := e.store.Pending(ctx, e.cfg.Installation)
	if err != nil {
		return err
	}
	// One request per tick keeps control envelopes below the wire ceiling.
	if len(batches) == 0 {
		return nil
	}
	b := batches[0]
	b.Directory = &Directory{Label: "User " + b.Control.UserID[:8], Revision: b.Control.Revision, Removed: b.Control.DeletionCutoff > 0 && !b.Control.Enabled}
	if !e.store.Current(ctx, b) {
		return ErrRevoked
	}
	body, err := json.Marshal(b)
	if err != nil || len(body) > MaxBody {
		return ErrInvalid
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, e.cfg.Endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+e.cfg.Credential)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-LocalFlow-Installation", e.cfg.Installation)
	res, err := e.client.Do(req)
	if err != nil {
		return errors.New("usage: export unavailable")
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, MaxBody+1))
	if err != nil || len(data) > MaxBody {
		return ErrInvalid
	}
	if res.StatusCode != http.StatusNoContent {
		return errors.New("usage: export refused")
	}
	if err = e.store.AcknowledgeControl(ctx, b); err != nil {
		return err
	}
	return e.store.AcknowledgeRows(ctx, b)
}
func (e *Exporter) Run(ctx context.Context) {
	delay := 30 * time.Second
	for {
		t := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		}
		if err := e.Once(ctx); err != nil {
			delay = min(delay*2, time.Hour)
		} else {
			delay = 30 * time.Second
		}
	}
}

func (e *Exporter) pollDeletion(ctx context.Context) error {
	endpoint := strings.TrimSuffix(e.cfg.Endpoint, "/v1/ingest/usage") + "/v1/control/deletions"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+e.cfg.Credential)
	req.Header.Set("X-LocalFlow-Installation", e.cfg.Installation)
	res, err := e.client.Do(req)
	if err != nil {
		return errors.New("usage: control unavailable")
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, MaxBody+1))
	if err != nil || len(data) > MaxBody || res.StatusCode != 200 {
		return errors.New("usage: control refused")
	}
	var body struct {
		Users []string `json:"users"`
	}
	if json.Unmarshal(data, &body) != nil || len(body.Users) > 100 {
		return ErrInvalid
	}
	for _, user := range body.Users {
		if err = e.store.DeleteProjectedUser(ctx, user); err != nil {
			return err
		}
	}
	return nil
}
