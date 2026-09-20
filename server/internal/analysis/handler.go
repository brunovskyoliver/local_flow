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

type HandlerConfig struct {
	Backend          BackendAdapter
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
	return &Handler{config: c, slots: make(chan struct{}, c.Limits.Concurrency)}
}

func (h *Handler) backendInfo(ctx context.Context) backend.Info {
	h.probeMu.Lock()
	defer h.probeMu.Unlock()
	if h.probedAt.IsZero() || time.Since(h.probedAt) >= 5*time.Second {
		h.probe = h.config.Backend.Probe(ctx)
		h.probe.Model = boundIdentity(h.probe.Model)
		h.probedAt = time.Now()
	}
	return h.probe
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
		h.health(w, r)
		return
	}
	if r.Method != "POST" {
		w.Header().Set("Allow", "POST")
		w.WriteHeader(405)
		return
	}
	h.meeting(w, r)
}

func (h *Handler) health(w http.ResponseWriter, r *http.Request) {
	info := h.backendInfo(r.Context())
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

func (h *Handler) meeting(w http.ResponseWriter, r *http.Request) {
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
	if h.config.Limits.ExceedsContext(req.InputTextBytes(), req.Stage) {
		httpError(w, 413, CodeTooLarge)
		return
	}
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	code := "succeeded"
	outputBytes := 0
	queueMS := int(time.Since(start).Milliseconds())
	preemptions := 0
	defer func() {
		h.config.Logger.Printf(
			"request_id=%s run_id=%s stage=%s input_bytes=%d output_bytes=%d duration_ms=%d queue_ms=%d preemptions=%d code=%s",
			req.RequestID, req.RunID, req.Stage, req.InputTextBytes(), outputBytes,
			time.Since(start).Milliseconds(), queueMS, preemptions, code)
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
	ctx, err := h.config.Gate.Enter(r.Context())
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
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	template, _ := prompts.For(req.Stage)
	info := h.backendInfo(ctx)
	if ctx.Err() != nil {
		code = "cancelled"
		return
	}
	if info.State != "ready" {
		fail(CodeBackendUnavailable)
		return
	}
	var responseSchema map[string]any
	system := template.Text
	if info.JSONSchema {
		responseSchema = ResponseFormat(req.Stage)
	}
	user, err := renderUserText(req)
	if err != nil {
		fail(CodeInvalidRequest)
		return
	}
	lastProgress := time.Now()
	generate := func(extra string) (backend.Completion, error) {
		return h.config.Backend.Generate(ctx, backend.Input{
			System:          system + extra,
			Text:            user,
			MaxOutputBytes:  h.config.Limits.OutputBytes,
			MaxOutputTokens: h.config.Limits.OutputTokens(req.Stage),
			ResponseSchema:  responseSchema,
			Progress: func(chars int) error {
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
	}
	var completion backend.Completion
	var analysisResult *Analysis
	completion, err = generate("")
	if err == nil {
		analysisResult, err = ValidateResult([]byte(completion.Text), req)
	}
	if err != nil {
		// One repair attempt when constrained decoding is available: resend
		// with the validation failure appended to the instruction.
		var re *RequestError
		if errors.As(err, &re) && info.JSONSchema {
			completion, err = generate(
				" The previous output failed validation: " + re.Reason + ". Correct it.")
			if err == nil {
				analysisResult, err = ValidateResult([]byte(completion.Text), req)
			}
		}
	}
	if err != nil {
		if errors.Is(context.Cause(ctx), ErrPreempted) {
			preemptions++
			fail(CodePreempted)
			return
		}
		if ctx.Err() != nil {
			code = "cancelled"
			return
		}
		var re *RequestError
		switch {
		case errors.As(err, &re):
			fail(re.Code)
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
		Backend:         BackendInfo{"openai-compatible", boundIdentity(completion.Model)},
		PromptVersion:   template.Version,
		PipelineVersion: "analysis_v1",
		Timing: Timing{
			QueueMS: &queueMS, FirstTokenMS: completion.FirstTokenMS,
			BackendMS: &completion.DurationMS,
		},
		Preemptions: preemptions,
		Analysis:    *analysisResult,
	})
	if merr != nil || len(data) > MaxLineBytes {
		fail(CodeOutputTooLarge)
		return
	}
	outputBytes = len(completion.Text)
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

// renderUserText quotes the request's evidence as one JSON document.
func renderUserText(req *Request) (string, error) {
	doc := map[string]any{
		"meeting":      req.Meeting,
		"participants": req.Participants,
	}
	if req.Segments != nil {
		doc["segments"] = req.Segments
	}
	if req.Notes != nil {
		doc["notes"] = req.Notes
	}
	if req.Partials != nil {
		doc["partials"] = req.Partials
	}
	data, err := json.Marshal(doc)
	if err != nil {
		return "", err
	}
	return string(data), nil
}
