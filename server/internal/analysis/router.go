package analysis

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"localflow/server/internal/backend"
)

// The client names its summary server in these headers on each analysis
// request (ADR 0021). Without them analysis runs on the loopback backend.
const (
	HeaderPrimaryURL   = "X-LocalFlow-Primary-URL"
	HeaderPrimaryModel = "X-LocalFlow-Primary-Model"
	HeaderPrimaryKey   = "X-LocalFlow-Primary-Key"
	// HeaderPrimaryOnly "1" sends the request to the primary alone: no
	// fallback onto the loopback backend (Feature 018 R9). The client then
	// retries over its channel to the LocalFlow server.
	HeaderPrimaryOnly = "X-LocalFlow-Primary-Only"
)

// Router picks each analysis request's backend: the client's primary with
// the loopback backend as fallback, the primary alone, or the loopback
// backend alone.
type Router struct {
	Local                      *backend.OpenAI
	Gate                       *Gate
	FirstTokenTimeout, Timeout time.Duration

	mu      sync.Mutex
	key     string
	current BackendAdapter
}

// For returns the request's backend. The last primary is reused while the
// client keeps sending the same one.
// ponytail: one cached primary; a replaced adapter's idle connections close on their own.
func (r *Router) For(req *http.Request) (BackendAdapter, error) {
	url := req.Header.Get(HeaderPrimaryURL)
	if url == "" {
		return r.Local, nil
	}
	model, token := req.Header.Get(HeaderPrimaryModel), req.Header.Get(HeaderPrimaryKey)
	if model == "" || len(model) > 128 || len(token) > 4096 || strings.ContainsAny(token, "\r\n") {
		return nil, errors.New("invalid primary backend")
	}
	only := req.Header.Get(HeaderPrimaryOnly) == "1"
	key := url + "\x00" + model + "\x00" + token + "\x00" + strconv.FormatBool(only)
	r.mu.Lock()
	defer r.mu.Unlock()
	if key == r.key {
		return r.current, nil
	}
	primary, err := backend.New(backend.Config{
		BaseURL: url, Model: model, Token: token,
		FirstTokenTimeout: r.FirstTokenTimeout, Timeout: r.Timeout,
	})
	if err != nil {
		return nil, err
	}
	r.key, r.current = key, primary
	if !only {
		fallback := &backend.Fallback{Primary: primary, Secondary: r.Local}
		fallback.GuardLocal(r.Gate.Guard)
		r.current = fallback
	}
	return r.current, nil
}
