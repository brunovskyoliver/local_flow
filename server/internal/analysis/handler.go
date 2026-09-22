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
	if c.Limits.Timeout < 1 {
		c.Limits.Timeout = 300 * time.Second
	}
	if c.Limits.FirstTokenTimeout < 1 {
		c.Limits.FirstTokenTimeout = 60 * time.Second
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
	// Content-free reason behind a failure code: our own sentinel and reason
	// strings (a backend HTTP status, a stream shape, a validation rule).
	detail := "-"
	outputBytes := 0
	queueMS := int(time.Since(start).Milliseconds())
	preemptions := 0
	// Why each rejected attempt failed, in the same content-free vocabulary
	// as detail: a request that burned its repairs shows which rule it hit.
	var rejected []string
	defer func() {
		reasons := "-"
		if len(rejected) > 0 {
			reasons = strings.Join(rejected, ",")
		}
		h.config.Logger.Printf(
			"request_id=%s run_id=%s stage=%s input_bytes=%d output_bytes=%d duration_ms=%d queue_ms=%d preemptions=%d attempts=%d rejected=%s code=%s detail=%s",
			req.RequestID, req.RunID, req.Stage, req.InputTextBytes(), outputBytes,
			time.Since(start).Milliseconds(), queueMS, preemptions, len(rejected)+1,
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
	template, _ := prompts.For(req.Stage, req.Meeting.LanguagePolicy.Output)
	info := h.backendInfo(ctx)
	if ctx.Err() != nil {
		code = "cancelled"
		return
	}
	if info.State != "ready" {
		fail(CodeBackendUnavailable)
		return
	}
	system := template.Text + schemaClause
	// Constrained decoding only where the backend advertises it: an engine
	// that accepts response_format without advertising can degenerate on a
	// schema this size — MTPLX burned the whole token budget to emit a few
	// hundred bytes. Everywhere else the in-prompt schema plus validation
	// and the repair attempt carry the shape.
	var responseSchema map[string]any
	if info.JSONSchema {
		responseSchema = ResponseFormat(req.Stage)
	}
	user, err := renderUserText(req)
	if err != nil {
		fail(CodeInvalidRequest)
		return
	}
	lastProgress := time.Now()
	generate := func(extra string, temperature *float64) (backend.Completion, error) {
		return h.config.Backend.Generate(ctx, backend.Input{
			System:            system + extra,
			Text:              user,
			MaxOutputBytes:    h.config.Limits.OutputBytes,
			MaxOutputTokens:   h.config.Limits.OutputTokens(req.Stage),
			Timeout:           h.config.Limits.Timeout,
			FirstTokenTimeout: h.config.Limits.FirstTokenTimeout,
			ResponseSchema:    responseSchema,
			Temperature:       temperature,
			ReasoningOff:      true,
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
	// Cut at the token cap? Name it, so the repair attempt knows to answer
	// shorter rather than chase a phantom syntax fault.
	validate := func(c backend.Completion) (*Analysis, error) {
		result, err := ValidateResult([]byte(c.Text), req)
		if err != nil && c.Truncated {
			err = &RequestError{CodeOutputInvalid, "truncated at the output token limit"}
		}
		return result, err
	}
	var completion backend.Completion
	var analysisResult *Analysis
	completion, err = generate("", nil)
	if err == nil {
		analysisResult, err = validate(completion)
	}
	if err != nil {
		// Repair attempts on any validation failure: the result schema is in
		// the system prompt on every request, so the failure text is always
		// actionable. A truncated answer needs a smaller one, not a syntax
		// fix. The raised temperature escapes greedy-decoding attractors — at
		// temperature 0 a near-identical prompt reproduces the same failure.
		var re *RequestError
		for _, temp := range repairTemperatures {
			if !errors.As(err, &re) {
				break
			}
			rejected = append(rejected, strings.ReplaceAll(re.Reason, " ", "_"))
			hint := " The previous output failed validation: " + re.Reason + ". Correct it."
			if completion.Truncated {
				hint = " The previous output was cut off at the token limit. Produce a shorter result: keep only the most significant topics and items."
			}
			completion, err = generate(hint, &temp)
			if err == nil {
				analysisResult, err = validate(completion)
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
		detail = strings.ReplaceAll(err.Error(), " ", "_")
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

// repairTemperatures drive the two repair attempts: a mild perturbation
// escapes a deterministic repetition attractor, a stronger one re-rolls an
// output that was still broken — the failure hint alone does not move a
// temperature-0 decode off its attractor.
var repairTemperatures = []float64{0.3, 0.5}

// schemaClause carries the compacted result schema between two directives: the
// tail keeps the prompt from ending on JSON, which small models mistake for a
// document to echo, and asks for compact output — constrained backends emit
// whitespace tokens the budget would otherwise pay for.
const schemaClauseHead = "This is the JSON Schema the result must match: "
const schemaClauseTail = " Reply with exactly one JSON object matching it — compact, no indentation or extra whitespace, no markdown fence, no text before or after the object, and never a copy of the schema itself. Report only what matters: a shorter accurate result beats a long padded one. Cite at most 10 sources per list — pick the few most representative segments, not every related one. Never exceed the schema's maxItems limits: keep only the most significant entries (e.g. at most 12 bullets per topic, a handful of strong topics rather than every minor aside)."

// The prompt's schema drops `format`: ids reach the model as short aliases
// ("s12", "p2"), not the UUIDs the wire schema declares.
var schemaClause = func() string {
	var doc map[string]any
	if json.Unmarshal(resultSchemaJSON, &doc) != nil {
		return schemaClauseHead + string(resultSchemaJSON) + schemaClauseTail
	}
	stripKeys(doc, map[string]bool{"format": true})
	data, err := json.Marshal(doc)
	if err != nil {
		return schemaClauseHead + string(resultSchemaJSON) + schemaClauseTail
	}
	return schemaClauseHead + string(data) + schemaClauseTail
}()

// renderUserText quotes the request's evidence as one JSON document, with
// short id aliases in place of UUIDs (see idAliases).
func renderUserText(req *Request) (string, error) {
	doc, err := aliasedDocument(req, newAliases(req))
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(doc)
	if err != nil {
		return "", err
	}
	return string(data), nil
}
