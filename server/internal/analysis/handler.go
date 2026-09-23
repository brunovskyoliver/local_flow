package analysis

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"localflow/server/internal/analysis/prompts"
	"localflow/server/internal/backend"
)

// BackendAdapter is the inference surface the handler needs.
type BackendAdapter interface {
	Probe(context.Context) backend.Info
	Generate(context.Context, backend.Input) (backend.Completion, error)
}

// cacheClearer is the optional backend hook that drops the inference
// process's prompt and session caches once a meeting's analysis is done.
type cacheClearer interface {
	ClearCache(context.Context) error
}

// localGuarded is a backend that may serve a call off this machine: it takes
// the gate and applies it only to the calls it runs locally.
type localGuarded interface {
	GuardLocal(func(context.Context) (context.Context, func(), error))
}

type HandlerConfig struct {
	Backend BackendAdapter
	// Route, when set, picks each request's backend in place of Backend.
	Route            func(*http.Request) (BackendAdapter, error)
	Token            string
	ProtocolVersions []int
	Limits           Limits
	Gate             *Gate
	Logger           *log.Logger
	// DumpDir, honoured only in localflow_debug builds, writes each request
	// body to <dir>/<request_id>.json mode 0600.
	DumpDir string
}

type Handler struct {
	config    HandlerConfig
	slots     chan struct{}
	probeMu   sync.Mutex
	probedAt  time.Time
	probedFor BackendAdapter
	probe     backend.Info
	generated atomic.Uint64
}

func NewHandler(c HandlerConfig) *Handler {
	if len(c.ProtocolVersions) == 0 {
		c.ProtocolVersions = []int{1}
	}
	c.ProtocolVersions = append([]int(nil), c.ProtocolVersions...)
	if c.Logger == nil {
		c.Logger = log.New(io.Discard, "", 0)
	}
	if c.Gate == nil {
		c.Gate = NewGate(0, false)
	}
	if c.Limits.Concurrency < 1 {
		c.Limits.Concurrency = 1
	}
	if c.Limits.InputBytes < 1 {
		c.Limits.InputBytes = 98304
	}
	if c.Limits.OutputBytes < 1 {
		c.Limits.OutputBytes = MaxLineBytes
	}
	if c.Limits.Timeout < 1 {
		c.Limits.Timeout = 270 * time.Second
	}
	if c.Limits.FirstTokenTimeout < 1 {
		c.Limits.FirstTokenTimeout = 60 * time.Second
	}
	if b, ok := c.Backend.(localGuarded); ok {
		b.GuardLocal(c.Gate.Guard)
	}
	return &Handler{config: c, slots: make(chan struct{}, c.Limits.Concurrency)}
}

func (h *Handler) route(r *http.Request) (BackendAdapter, error) {
	if h.config.Route == nil {
		return h.config.Backend, nil
	}
	return h.config.Route(r)
}

func (h *Handler) backendInfo(ctx context.Context, b BackendAdapter) backend.Info {
	h.probeMu.Lock()
	defer h.probeMu.Unlock()
	if h.probedFor != b || h.probedAt.IsZero() || time.Since(h.probedAt) >= 5*time.Second {
		h.probe = b.Probe(ctx)
		h.probe.Model = boundIdentity(h.probe.Model)
		h.probedAt, h.probedFor = time.Now(), b
	}
	return h.probe
}

func (h *Handler) clearBackendCache(b BackendAdapter) {
	clearer, ok := b.(cacheClearer)
	if !ok {
		return
	}
	go func() {
		if err := clearer.ClearCache(context.Background()); err != nil {
			h.config.Logger.Printf("analysis cache_clear failed detail=%s", strings.ReplaceAll(err.Error(), " ", "_"))
		}
	}()
}

func boundIdentity(s string) string {
	if len(s) <= MaxIdentityBytes {
		return s
	}
	cut := MaxIdentityBytes
	for cut > 0 && (s[cut]&0xc0) == 0x80 {
		cut--
	}
	return s[:cut]
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/v1/analysis/meeting" && r.URL.Path != "/v1/analysis/health" {
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
	if r.URL.Path == "/v1/analysis/health" {
		if r.Method != "GET" {
			w.Header().Set("Allow", "GET")
			w.WriteHeader(405)
			return
		}
		b, err := h.route(r)
		if err != nil {
			httpError(w, 400, CodeInvalidRequest)
			return
		}
		h.health(w, r, b)
		return
	}
	if r.Method != "POST" {
		w.Header().Set("Allow", "POST")
		w.WriteHeader(405)
		return
	}
	b, err := h.route(r)
	if err != nil {
		httpError(w, 400, CodeInvalidRequest)
		return
	}
	h.meeting(w, r, b)
}

func (h *Handler) health(w http.ResponseWriter, r *http.Request, b BackendAdapter) {
	info := h.backendInfo(r.Context(), b)
	l := h.config.Limits
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(Health{
		SchemaVersion:    SchemaVersion,
		Service:          ServiceName,
		ProtocolVersions: h.config.ProtocolVersions,
		Server:           Identity{"flowd", ServerVersion},
		Backend: HealthBackend{
			State: info.State, Kind: "openai-compatible", Model: info.Model,
			JSONSchema: info.JSONSchema,
		},
		PromptVersions: prompts.Versions(),
		ResultSchema:   SchemaVersion,
		Limits: HealthLimits{
			InputBytes:    l.InputBytes,
			OutputBytes:   l.OutputBytes,
			ContextTokens: l.ContextTokens,
			Concurrency:   l.Concurrency,
		},
		Caps: HealthCaps{
			SourcesPerItem: MaxSourcesPerItem, Topics: fullCaps["topics"],
			Decisions: fullCaps["decisions"], ActionItems: fullCaps["action_items"],
			NextSteps: fullCaps["next_steps"], OpenQuestions: fullCaps["open_questions"],
			Risks: fullCaps["risks"],
		},
	})
}

func httpError(w http.ResponseWriter, status int, code Code) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(NewErrorBody(code))
}

// writeEvent is one NDJSON write with a deadline so a stalled peer cannot hold
// the analysis slot.
func writeEvent(w http.ResponseWriter, data []byte) error {
	controller := http.NewResponseController(w)
	_ = controller.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if _, err := w.Write(data); err != nil {
		return err
	}
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
	return nil
}

func encodeLine(v any) ([]byte, error) {
	data, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

func (h *Handler) meeting(w http.ResponseWriter, r *http.Request, b BackendAdapter) {
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
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(30 * time.Second))
	body, err := io.ReadAll(io.LimitReader(r.Body, MaxRequestBodyBytes+1))
	if err != nil {
		httpError(w, 413, CodeTooLarge)
		return
	}
	if DebugBuild && h.config.DumpDir != "" && len(body) > 0 {
		dumpRequestBody(h.config.DumpDir, body)
	}
	req, err := DecodeRequestBytes(body, h.config.Limits.InputBytes)
	if err != nil {
		var re *RequestError
		if errors.As(err, &re) {
			status := 400
			if re.Code == CodeTooLarge {
				status = 413
			}
			httpError(w, status, re.Code)
		} else {
			httpError(w, 400, CodeInvalidRequest)
		}
		return
	}
	supported := false
	for _, v := range h.config.ProtocolVersions {
		if v == SchemaVersion {
			supported = true
		}
	}
	if !supported {
		httpError(w, 400, CodeUnsupportedVersion)
		return
	}
	// Full and synthesis are a meeting's last analysis call; chunks still
	// share the cached prompt prefix. Clearing after the response keeps the
	// backend's KV and MLX buffers from lingering between meetings.
	if req.Stage != StageChunk {
		defer h.clearBackendCache(b)
	}
	if h.config.Limits.ExceedsContext(req.InputTextBytes(), req.Stage) {
		httpError(w, 413, CodeTooLarge)
		return
	}
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	code := "succeeded"
	// Content-free reason behind a failure code: our own sentinel and reason
	// strings (a backend HTTP status, a stream shape, a validation rule).
	detail := "-"
	outputBytes := 0
	queueMS := int(time.Since(start).Milliseconds())
	preemptions := 0
	// Why each rejected attempt failed, in the same content-free vocabulary
	// as detail: a request that burned its repairs shows which rule it hit.
	var rejected []string
	// Backend calls this request made, and the model that answered the last
	// one — which of a primary and its fallback served it.
	attempts, served := 0, "-"
	defer func() {
		reasons := "-"
		if len(rejected) > 0 {
			reasons = strings.Join(rejected, ",")
		}
		h.config.Logger.Printf(
			"request_id=%s run_id=%s stage=%s input_bytes=%d output_bytes=%d duration_ms=%d queue_ms=%d preemptions=%d attempts=%d model=%s rejected=%s code=%s detail=%s",
			req.RequestID, req.RunID, req.Stage, req.InputTextBytes(), outputBytes,
			time.Since(start).Milliseconds(), queueMS, preemptions, attempts, served,
			reasons, code, detail)
	}()
	send := func(v any) bool {
		data, err := encodeLine(v)
		if err != nil || len(data) > MaxLineBytes {
			return false
		}
		return writeEvent(w, data) == nil
	}
	fail := func(c Code) {
		code = string(c)
		_ = send(Error(req.RequestID, c))
	}
	if !send(Accepted(req.RequestID)) {
		code = "cancelled"
		return
	}
	ctx := r.Context()
	// A backend that gates its own local calls skips the request-wide gate.
	if _, guarded := b.(localGuarded); !guarded {
		ctx, err = h.config.Gate.Enter(ctx)
		if err != nil {
			var re *RequestError
			if errors.As(err, &re) {
				fail(re.Code)
			} else {
				code = "cancelled"
			}
			return
		}
		defer h.config.Gate.Leave()
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	info := h.backendInfo(ctx, b)
	if ctx.Err() != nil {
		code = "cancelled"
		return
	}
	if info.State != "ready" {
		fail(CodeBackendUnavailable)
		return
	}
	// One request runs several backend calls (ADR 0022); --analysis-timeout
	// bounds all of them together, so the client's per-request deadline sees
	// an answer or an error, never silence.
	deadline := start.Add(h.config.Limits.Timeout)
	lastProgress := time.Now()
	chars := 0
	var firstTokenMS *int
	backendMS := 0
	model := info.Model
	generate := func(ctx context.Context, system, user string, maxTokens int, temperature float64) (string, error) {
		timeout := time.Until(deadline)
		if timeout <= 0 {
			return "", backend.ErrTimeout
		}
		attempts++
		base := chars
		c, err := b.Generate(ctx, backend.Input{
			System:            system,
			Text:              user,
			MaxOutputBytes:    h.config.Limits.OutputBytes,
			MaxOutputTokens:   maxTokens,
			Timeout:           timeout,
			FirstTokenTimeout: h.config.Limits.FirstTokenTimeout,
			Temperature:       &temperature,
			ReasoningOff:      true,
			Progress: func(n int) error {
				chars = base + n
				if time.Since(lastProgress) < 250*time.Millisecond {
					return nil
				}
				lastProgress = time.Now()
				if !send(Progress(req.RequestID, req.Stage, chars)) {
					return errors.New("client gone")
				}
				return nil
			},
		})
		if err != nil {
			return "", err
		}
		if firstTokenMS == nil {
			firstTokenMS = c.FirstTokenMS
		}
		backendMS += c.DurationMS
		if c.Model != "" {
			model, served = c.Model, strings.ReplaceAll(c.Model, " ", "_")
		}
		outputBytes += len(c.Text)
		if c.Truncated {
			rejected = append(rejected, "truncated")
		}
		return c.Text, nil
	}
	p := newPipeline(req, generate, h.config.Limits, deadline)
	analysisResult, err := p.run(ctx)
	rejected = append(rejected, p.rejected...)
	if err == nil {
		// The pipeline built the result in code; the protocol's own checks
		// still run before it goes on the wire.
		if err = validateStructure(analysisResult, req.Stage == StageChunk); err == nil {
			err = validateSources(analysisResult, req)
		}
	}
	if err != nil {
		// A guarded backend preempts inside its own call context.
		if errors.Is(context.Cause(ctx), ErrPreempted) || errors.Is(err, ErrPreempted) {
			preemptions++
			fail(CodePreempted)
			return
		}
		if ctx.Err() != nil {
			code = "cancelled"
			return
		}
		detail = strings.ReplaceAll(err.Error(), " ", "_")
		var re *RequestError
		switch {
		case errors.As(err, &re):
			fail(re.Code)
		case errors.Is(err, backend.ErrTooLarge):
			fail(CodeTooLarge)
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
	data, merr := encodeLine(ResultEvent{
		SchemaVersion: SchemaVersion, Type: "result", RequestID: req.RequestID,
		RunID: req.RunID, Stage: req.Stage, Server: Identity{"flowd", ServerVersion},
		Backend:         BackendInfo{"openai-compatible", boundIdentity(model)},
		PromptVersion:   prompts.Version,
		PipelineVersion: "analysis_v2",
		Timing: Timing{
			QueueMS: &queueMS, FirstTokenMS: firstTokenMS,
			BackendMS: &backendMS,
		},
		Preemptions: preemptions,
		Analysis:    *analysisResult,
	})
	if merr != nil || len(data) > MaxLineBytes {
		fail(CodeOutputTooLarge)
		return
	}
	if writeEvent(w, data) != nil {
		code = "cancelled"
	}
}

// dumpRequestBody writes one request body to <dir>/<request_id>.json with
// private permissions. Compiled to a no-op outside localflow_debug builds.
func dumpRequestBody(dir string, body []byte) {
	type header struct {
		RequestID string `json:"request_id"`
	}
	var h header
	_ = json.Unmarshal(body, &h)
	name := h.RequestID
	if name == "" {
		name = "unknown"
	}
	// request_id is a UUID or absent; strip anything path-like as a precaution.
	name = strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' {
			return r
		}
		return '_'
	}, name)
	_ = os.MkdirAll(dir, 0o700)
	_ = os.WriteFile(filepath.Join(dir, name+".json"), body, 0o600)
}
