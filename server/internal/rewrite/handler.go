package rewrite

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"localflow/server/internal/backend"
	"localflow/server/internal/rewrite/disfluency"
	"localflow/server/internal/rewrite/prompts"
	entityshield "localflow/server/internal/rewrite/shield"
)

const ServerVersion = "0.3.0"

type BackendAdapter interface {
	Probe(context.Context) backend.Info
	Generate(context.Context, backend.Input) (backend.Completion, error)
}

// PriorityGate lets the rewrite handler announce itself to the analysis
// rewrite-first gate without importing the analysis package.
type PriorityGate interface {
	RewriteStart() func()
}

type HandlerConfig struct {
	Backend          BackendAdapter
	Token            string
	Shield           bool
	ProtocolVersions []int
	Logger           *log.Logger
	// Gate, when set, counts this handler's in-flight rewrites and preempts
	// analysis work.
	Gate PriorityGate
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
		c.ProtocolVersions = []int{SchemaVersion, ContextVersion}
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

// RunCancelled is what Run returns when ctx ended or emit failed before a
// terminal event was written. It is never sent.
const RunCancelled ErrorCode = "cancelled"

// admit takes one of the MaxConcurrentRequests slots and registers with the
// analysis gate. HTTP requests and Run share both.
func (h *Handler) admit() (release func(), ok bool) {
	select {
	case h.slots <- struct{}{}:
	default:
		return nil, false
	}
	gateRelease := func() {}
	if h.config.Gate != nil {
		gateRelease = h.config.Gate.RewriteStart()
	}
	return func() {
		gateRelease()
		<-h.slots
	}, true
}

func (h *Handler) supports(version int) bool {
	for _, v := range h.config.ProtocolVersions {
		if v == version {
			return true
		}
	}
	return false
}

func (h *Handler) rewrite(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	if r.ContentLength > MaxRequestBodyBytes {
		httpError(w, 413, CodeTooLarge)
		return
	}
	release, ok := h.admit()
	if !ok {
		httpError(w, 429, CodeServerBusy)
		return
	}
	defer release()
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
	if !h.supports(req.SchemaVersion) {
		httpError(w, 400, CodeUnsupportedVersion)
		return
	}
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	h.run(r.Context(), req, start, func(line []byte) error { return writeEvent(w, line) })
}

// Run performs one decoded rewrite request outside HTTP, for the remote
// channel's rewrite operation. It takes a slot of the same limit of
// MaxConcurrentRequests and the same analysis gate as the HTTP route, then
// calls emit once per event with exactly the NDJSON line (trailing newline
// included) the HTTP route would write, ending with the result or error line.
// A request refused before streaming (server_busy, unsupported_version) emits
// a single error line. Run returns "" after a result, the error code after an
// error line, or RunCancelled when ctx ended or emit failed.
func (h *Handler) Run(ctx context.Context, req Request, emit func(line []byte) error) ErrorCode {
	start := time.Now()
	refuse := func(code ErrorCode) ErrorCode {
		data, err := EncodeLine(Error(req.RequestID, code, message(code)))
		if err != nil || emit(data) != nil {
			return RunCancelled
		}
		return code
	}
	release, ok := h.admit()
	if !ok {
		return refuse(CodeServerBusy)
	}
	defer release()
	if !h.supports(req.SchemaVersion) {
		return refuse(CodeUnsupportedVersion)
	}
	return h.run(ctx, req, start, emit)
}

// run streams one admitted, decoded and version-checked request through emit.
func (h *Handler) run(parent context.Context, req Request, start time.Time, emit func([]byte) error) ErrorCode {
	queueMS := int(time.Since(start).Milliseconds())
	code := "succeeded"
	outputBytes := 0
	contextBytes := ""
	if req.Context != nil {
		contextBytes = fmt.Sprintf(" context_bytes=%d", len(req.ContextJSON))
	}
	defer func() {
		h.config.Logger.Printf("request_id=%s input_bytes=%d%s output_bytes=%d duration_ms=%d code=%s", req.RequestID, len(req.Text), contextBytes, outputBytes, time.Since(start).Milliseconds(), code)
	}()
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
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
		return emit(data)
	}
	if send(Accepted(req.RequestID)) != nil {
		code = "cancelled"
		return RunCancelled
	}
	fail := func(c ErrorCode) ErrorCode {
		code = string(c)
		if c == CodeOutputTooLarge {
			h.outputTooLarge.Add(1)
		}
		if send(Error(req.RequestID, c, message(c))) != nil {
			return RunCancelled
		}
		return c
	}
	template, _ := prompts.For(req.Mode)
	input := req.Text
	var table entityshield.Table
	shieldVersion := 0
	restored := 0
	if strings.ContainsAny(input, "⟦⟧") {
		return fail(CodeShieldRestoreFailed)
	}
	// Hesitation sounds are never content; the model need not see them.
	spoken := disfluency.Signals(input)
	input = disfluency.Strip(input, req.LanguageHints)
	stripped := input
	if h.config.Shield {
		input, table = entityshield.Shield(input)
		shieldVersion = entityshield.Version
	}
	info := h.backendInfo(ctx)
	if ctx.Err() != nil {
		code = "cancelled"
		return RunCancelled
	}
	if info.State != "ready" {
		return fail(CodeBackendUnavailable)
	}
	lastProgress := time.Now()
	// The spoken rules clean up disfluent speech but can over-edit. An output
	// that fails validation under them is regenerated once with the plain mode
	// template, whose behaviour predates them, before the request fails.
	systems := []string{template.Text}
	if spoken {
		systems = []string{prompts.WithSpoken(template.Text), template.Text}
	}
	var responseSchema map[string]any
	if info.JSONSchema {
		responseSchema = prompts.ResponseFormat()
	}
	var completion backend.Completion
	var text string
	backendMS := 0
	for attempt, system := range systems {
		if req.Context != nil {
			system = prompts.WithContext(system, prompts.Reference{Category: req.Context.AppCategory, StyleHints: req.Context.StyleHints, Block: RenderContext(req.ContextJSON)})
		}
		if info.JSONSchema {
			system += prompts.ConstrainedInstruction
		}
		var err error
		completion, err = h.config.Backend.Generate(ctx, backend.Input{System: system, Text: input, MaxOutputBytes: req.MaxOutputBytes(), ResponseSchema: responseSchema, Progress: func(chars int) error {
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
				return RunCancelled
			}
			switch {
			case errors.Is(err, backend.ErrOutputTooLarge):
				return fail(CodeOutputTooLarge)
			case errors.Is(err, backend.ErrFirstTokenTimeout):
				return fail(CodeBackendFirstTokenTimeout)
			case errors.Is(err, backend.ErrTimeout):
				return fail(CodeBackendTimeout)
			case errors.Is(err, backend.ErrUnavailable):
				return fail(CodeBackendUnavailable)
			default:
				return fail(CodeBackendError)
			}
		}
		backendMS += completion.DurationMS
		var invalid ErrorCode
		// Polished and concise may legitimately merge or drop sentences, so
		// only clean output is held to keeping every one.
		text, restored, invalid = h.validate(req, completion.Text, info.JSONSchema, table, stripped, attempt == 0 && spoken && req.Mode == "clean")
		if invalid == "" {
			break
		}
		if attempt == len(systems)-1 {
			return fail(invalid)
		}
		h.config.Logger.Printf("request_id=%s spoken_retry=%s", req.RequestID, invalid)
	}
	timing := Timing{&queueMS, completion.FirstTokenMS, &backendMS}
	result := NewResult(req, text, Identity{"flowd", ServerVersion}, Backend{"openai-compatible", BoundIdentity(completion.Model)}, template.Version, Shield{shieldVersion, len(table.Shielded), restored}, timing)
	if req.Context != nil {
		result.ContextPromptVersion = prompts.ContextPromptVersion
	}
	// JSON escaping can expand text. Enforce the client's total response budget
	// as well as its text budget before emitting a terminal result.
	data, err := EncodeLine(result)
	if err != nil || responseBytes+len(data) > responseLimit {
		return fail(CodeOutputTooLarge)
	}
	outputBytes = len(text)
	responseBytes += len(data)
	if emit(data) != nil {
		code = "cancelled"
		return RunCancelled
	}
	return ""
}

// validate decodes and checks one backend output and restores its shielded
// values. keepSentences additionally rejects outputs that dropped a whole
// sentence, which the spoken rules can cause and a retry without them avoids.
func (h *Handler) validate(req Request, raw string, jsonSchema bool, table entityshield.Table, input string, keepSentences bool) (string, int, ErrorCode) {
	text := raw
	if jsonSchema {
		var decoded string
		if json.Unmarshal([]byte(text), &decoded) != nil {
			return "", 0, CodeBackendError
		}
		text = decoded
	}
	if strings.TrimSpace(text) == "" {
		return "", 0, CodeBackendError
	}
	restored := 0
	if h.config.Shield {
		var err error
		text, restored, err = entityshield.Restore(text, table)
		if err != nil {
			return "", 0, CodeShieldRestoreFailed
		}
	}
	if len(text) > req.MaxOutputBytes() {
		return "", 0, CodeOutputTooLarge
	}
	if strings.ContainsAny(text, "⟦⟧") || hasCommentary(text) || disfluency.HalfCorrected(input, text) {
		return "", 0, CodeBackendError
	}
	if keepSentences && disfluency.DroppedSentence(input, text) {
		return "", 0, CodeBackendError
	}
	return text, restored, ""
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
