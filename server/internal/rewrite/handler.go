package rewrite

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"localflow/server/internal/rewrite/backend"
	"localflow/server/internal/rewrite/prompts"
	entityshield "localflow/server/internal/rewrite/shield"
)

const ServerVersion = "0.2.0"

type BackendAdapter interface {
	Probe(context.Context) backend.Info
	Generate(context.Context, backend.Input) (backend.Completion, error)
}
type HandlerConfig struct {
	Backend          BackendAdapter
	Token            string
	Shield           bool
	ProtocolVersions []int
	Logger           *log.Logger
}
type Handler struct {
	config         HandlerConfig
	slots          chan struct{}
	probeMu        sync.Mutex
	probedAt       time.Time
	probe          backend.Info
	outputTooLarge atomic.Uint64
}

func NewHandler(c HandlerConfig) *Handler {
	if len(c.ProtocolVersions) == 0 {
		c.ProtocolVersions = []int{1}
	}
	c.ProtocolVersions = append([]int(nil), c.ProtocolVersions...)
	if c.Logger == nil {
		c.Logger = log.New(io.Discard, "", 0)
	}
	return &Handler{config: c, slots: make(chan struct{}, MaxConcurrentRequests)}
}
func (h *Handler) OutputTooLargeCount() uint64 { return h.outputTooLarge.Load() }
func (h *Handler) backendInfo(ctx context.Context) backend.Info {
	h.probeMu.Lock()
	defer h.probeMu.Unlock()
	if h.probedAt.IsZero() || time.Since(h.probedAt) >= ProbeInterval {
		h.probe = h.config.Backend.Probe(ctx)
		h.probe.Model = BoundIdentity(h.probe.Model)
		h.probedAt = time.Now()
	}
	return h.probe
}
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/v1/rewrite" && r.URL.Path != "/v1/rewrite/health" {
		http.NotFound(w, r)
		return
	}
	if h.config.Token != "" {
		auth := r.Header.Get("Authorization")
		if auth == "" {
			httpError(w, 401, CodeUnauthorized)
			return
		}
		supplied := sha256.Sum256([]byte(auth))
		expected := sha256.Sum256([]byte("Bearer " + h.config.Token))
		if subtle.ConstantTimeCompare(supplied[:], expected[:]) != 1 {
			httpError(w, 403, CodeUnauthorized)
			return
		}
	}
	if r.URL.Path == "/v1/rewrite/health" {
		if r.Method != "GET" {
			w.Header().Set("Allow", "GET")
			w.WriteHeader(405)
			return
		}
		info := h.backendInfo(r.Context())
		version := 0
		if h.config.Shield {
			version = entityshield.Version
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(Health{1, ServiceName, h.config.ProtocolVersions, Identity{"flowd", ServerVersion}, Modes, HealthBackend{info.State, "openai-compatible", info.Model}, prompts.Versions(), version})
		return
	}
	if r.Method != "POST" {
		w.Header().Set("Allow", "POST")
		w.WriteHeader(405)
		return
	}
	h.rewrite(w, r)
}
func httpError(w http.ResponseWriter, status int, code ErrorCode) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(NewErrorBody(code, message(code)))
}
func message(code ErrorCode) string {
	switch code {
	case CodeUnauthorized:
		return "Authentication failed."
	case CodeTooLarge, CodeOutputTooLarge:
		return "The request or response exceeds the size limit."
	case CodeServerBusy:
		return "Two rewrites are already running."
	case CodeBackendUnavailable:
		return "The language model backend is not running."
	case CodeBackendTimeout, CodeBackendFirstTokenTimeout:
		return "The language model backend timed out."
	case CodeUnsupportedVersion:
		return "The protocol version is unsupported."
	case CodeInvalidRequest:
		return "The rewrite request is invalid."
	default:
		return "The language model output failed validation."
	}
}
func (h *Handler) rewrite(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	if r.ContentLength > MaxRequestBodyBytes {
		httpError(w, 413, CodeTooLarge)
		return
	}
	select {
	case h.slots <- struct{}{}:
		defer func() { <-h.slots }()
	default:
		httpError(w, 429, CodeServerBusy)
		return
	}
	// The slot also bounds simultaneous request-body decoding and shielding.
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(10 * time.Second))
	req, err := DecodeRequest(r.Body)
	if err != nil {
		var invalid *RequestError
		if errors.As(err, &invalid) {
			status := 400
			if invalid.Code == CodeTooLarge {
				status = 413
			}
			httpError(w, status, invalid.Code)
		} else {
			httpError(w, 400, CodeInvalidRequest)
		}
		return
	}
	supported := false
	for _, v := range h.config.ProtocolVersions {
		if v == 1 {
			supported = true
		}
	}
	if !supported {
		httpError(w, 400, CodeUnsupportedVersion)
		return
	}
	queueMS := int(time.Since(start).Milliseconds())
	code := "succeeded"
	outputBytes := 0
	defer func() {
		h.config.Logger.Printf("request_id=%s input_bytes=%d output_bytes=%d duration_ms=%d code=%s", req.RequestID, len(req.Text), outputBytes, time.Since(start).Milliseconds(), code)
	}()
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	responseBytes := 0
	responseLimit := min(4*req.InputBytes()+8192, 73728)
	send := func(v any) error {
		data, err := EncodeLine(v)
		if err != nil {
			return err
		}
		if responseBytes+len(data) > responseLimit {
			return ErrLineTooLong
		}
		responseBytes += len(data)
		return writeEvent(w, data)
	}
	if send(Accepted(req.RequestID)) != nil {
		code = "cancelled"
		return
	}
	fail := func(c ErrorCode) {
		code = string(c)
		if c == CodeOutputTooLarge {
			h.outputTooLarge.Add(1)
		}
		_ = send(Error(req.RequestID, c, message(c)))
	}
	template, _ := prompts.For(req.Mode)
	input := req.Text
	var table entityshield.Table
	shieldVersion := 0
	if strings.ContainsAny(input, "⟦⟧") {
		fail(CodeShieldRestoreFailed)
		return
	}
	if h.config.Shield {
		input, table = entityshield.Shield(input)
		shieldVersion = entityshield.Version
	}
	info := h.backendInfo(ctx)
	if ctx.Err() != nil {
		code = "cancelled"
		return
	}
	if info.State != "ready" {
		fail(CodeBackendUnavailable)
		return
	}
	lastProgress := time.Now()
	completion, err := h.config.Backend.Generate(ctx, backend.Input{System: template.Text, Text: input, MaxOutputBytes: req.MaxOutputBytes(), JSONSchema: info.JSONSchema, Progress: func(chars int) error {
		if time.Since(lastProgress) < ProgressInterval {
			return nil
		}
		lastProgress = time.Now()
		// Keep auxiliary events within 4 KiB, leaving room for identity and a terminal error.
		if responseBytes > 3800 {
			return nil
		}
		return send(Progress(req.RequestID, chars))
	}})
	if err != nil {
		if ctx.Err() != nil {
			code = "cancelled"
			return
		}
		switch {
		case errors.Is(err, backend.ErrOutputTooLarge):
			fail(CodeOutputTooLarge)
		case errors.Is(err, backend.ErrFirstTokenTimeout):
			fail(CodeBackendFirstTokenTimeout)
		case errors.Is(err, backend.ErrTimeout):
			fail(CodeBackendTimeout)
		case errors.Is(err, backend.ErrUnavailable):
			fail(CodeBackendUnavailable)
		default:
			fail(CodeBackendError)
		}
		return
	}
	text := completion.Text
	if strings.TrimSpace(text) == "" {
		fail(CodeBackendError)
		return
	}
	if h.config.Shield {
		text, err = entityshield.Restore(text, table)
		if err != nil {
			fail(CodeShieldRestoreFailed)
			return
		}
	}
	if len(text) > req.MaxOutputBytes() {
		fail(CodeOutputTooLarge)
		return
	}
	if strings.ContainsAny(text, "⟦⟧") || hasCommentary(text) {
		fail(CodeBackendError)
		return
	}
	timing := Timing{&queueMS, completion.FirstTokenMS, &completion.DurationMS}
	result := NewResult(req, text, Identity{"flowd", ServerVersion}, Backend{"openai-compatible", BoundIdentity(completion.Model)}, template.Version, Shield{shieldVersion, len(table), len(table)}, timing)
	// JSON escaping can expand text. Enforce the client's total response budget
	// as well as its text budget before emitting a terminal result.
	data, err := EncodeLine(result)
	if err != nil || responseBytes+len(data) > responseLimit {
		fail(CodeOutputTooLarge)
		return
	}
	outputBytes = len(text)
	responseBytes += len(data)
	if writeEvent(w, data) != nil {
		code = "cancelled"
	}
}
func hasCommentary(text string) bool {
	s := strings.ToLower(strings.TrimSpace(text))
	for _, prefix := range []string{"here is ", "here's ", "sure,", "sure!", "certainly,", "certainly!", "rewritten text:", "rewritten version:", "```", "<think>", "tu je prepis", "tu je upraven"} {
		if strings.HasPrefix(s, prefix) {
			return true
		}
	}
	return false
}
