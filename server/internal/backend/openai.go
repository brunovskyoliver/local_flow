// Package backend talks to a separately supervised inference process. It owns
// no model weights and never exposes backend error bodies to callers or logs.
package backend

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"
)

var (
	ErrOutputTooLarge    = errors.New("output_too_large")
	ErrFirstTokenTimeout = errors.New("backend_first_token_timeout")
	ErrTimeout           = errors.New("backend_timeout")
	ErrUnavailable       = errors.New("backend_unavailable")
	ErrBackend           = errors.New("backend_error")
	// ErrTooLarge is a request the backend refused for its size — context or
	// memory. It is not a backend fault: the caller splits the work and asks
	// again, and a fallback does not treat the primary as down.
	ErrTooLarge = errors.New("backend_too_large")
)

const maxSSELine = 65536

// MaxOutputBytes is the largest completion a caller may ask for.
const MaxOutputBytes = 131072
const maxErrorBody = 8192
const maxProbeBody = 65536

type Config struct {
	BaseURL, Model, Token                  string
	FirstTokenTimeout, Timeout, DebugDelay time.Duration
}
type OpenAI struct {
	config Config
	client *http.Client
}
type Info struct {
	State, Model string
	JSONSchema   bool
}
type Input struct {
	System, Text string
	// Followup, when set, is a second user message after Text. A repair hint
	// goes here, not in System: the prompt prefix stays identical to the
	// failed attempt, so the backend reuses its cached prefill.
	Followup        string
	MaxOutputBytes  int
	MaxOutputTokens int
	// Timeout and FirstTokenTimeout override the configured deadlines for this
	// call when positive; zero values keep the adapter's configured budgets.
	Timeout, FirstTokenTimeout time.Duration
	// ResponseSchema is sent as the OpenAI `response_format` value when set; the
	// caller also decides whether to append a constrained-output instruction.
	ResponseSchema map[string]any
	// Temperature overrides the request's sampling temperature when non-nil;
	// nil keeps the deterministic default of 0. A retry that must escape a
	// greedy-decoding attractor (repetition collapse) raises it.
	Temperature *float64
	// ReasoningOff sends `chat_template_kwargs.enable_thinking=false`. Reasoning
	// models burn the token budget on hidden thinking that never reaches the
	// content stream — Qwen3.x on MTPLX spent all 8,192 tokens on reasoning —
	// and the first-token deadline can't see it. Backends that ignore the field
	// are unaffected.
	ReasoningOff bool
	Progress     func(int) error
}
type Completion struct {
	Text, Model  string
	FirstTokenMS *int
	DurationMS   int
	// Truncated is true when the backend stopped at its token limit
	// (finish_reason=length); the text is delivered for the caller's
	// validation, which decides whether it is usable.
	Truncated bool
	// SchemaAccepted is true when the request carried response_format and the
	// backend did not reject it — the caller may treat the output as
	// schema-guided and offer a repair attempt on validation failure.
	SchemaAccepted bool
}

func New(c Config) (*OpenAI, error) {
	u, err := url.Parse(c.BaseURL)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" || c.Model == "" {
		return nil, errors.New("invalid backend configuration")
	}
	if c.FirstTokenTimeout == 0 {
		c.FirstTokenTimeout = 5 * time.Second
	}
	if c.Timeout == 0 {
		c.Timeout = 20 * time.Second
	}
	if c.FirstTokenTimeout < 0 || c.Timeout < 0 || c.DebugDelay < 0 {
		return nil, errors.New("invalid backend timeout")
	}
	c.BaseURL = strings.TrimRight(c.BaseURL, "/")
	// Requests go directly to the explicitly configured inference endpoint. No
	// environment proxy or redirect may send transcript text to another origin.
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.Proxy = nil
	tr.MaxConnsPerHost = 3
	tr.MaxIdleConnsPerHost = 3
	tr.MaxIdleConns = 3
	tr.DisableCompression = true
	// No ResponseHeaderTimeout: the per-call context deadline already bounds
	// the wait, and a transport timeout racing it would surface as unavailable
	// rather than backend_timeout.
	tr.MaxResponseHeaderBytes = 16384
	return &OpenAI{c, &http.Client{Transport: tr, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (a *OpenAI) Close() { a.client.CloseIdleConnections() }
func boundModel(s string) string {
	if len(s) <= 128 {
		return s
	}
	n := 128
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}
func (a *OpenAI) Probe(ctx context.Context) Info {
	info := Info{State: "unavailable", Model: boundModel(a.config.Model)}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", a.config.BaseURL+"/models", nil)
	if a.config.Token != "" {
		req.Header.Set("Authorization", "Bearer "+a.config.Token)
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return info
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, maxErrorBody))
		if resp.StatusCode == 503 {
			info.State = "loading"
		}
		return info
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxProbeBody+1))
	if err != nil || len(body) > maxProbeBody {
		return info
	}
	var models struct {
		Data []struct {
			ID           string
			Capabilities struct {
				JSONSchema bool `json:"json_schema"`
			}
		}
	}
	if json.Unmarshal(body, &models) != nil {
		return info
	}
	for _, m := range models.Data {
		if m.ID == a.config.Model {
			info.State = "ready"
			info.Model = boundModel(m.ID)
			info.JSONSchema = m.Capabilities.JSONSchema
			return info
		}
	}
	return info
}

// ClearCache asks the inference process to drop its session and prompt
// caches. MTPLX serves POST /admin/cache/clear at the server origin; other
// OpenAI-compatible servers answer 404, which the caller treats as a no-op.
func (a *OpenAI) ClearCache(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	origin := strings.TrimSuffix(a.config.BaseURL, "/v1")
	req, _ := http.NewRequestWithContext(ctx, "POST", origin+"/admin/cache/clear", nil)
	if a.config.Token != "" {
		req.Header.Set("Authorization", "Bearer "+a.config.Token)
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return ErrUnavailable
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, maxErrorBody))
	if resp.StatusCode != 200 {
		return fmt.Errorf("%w: status %d", ErrBackend, resp.StatusCode)
	}
	return nil
}

// Fixed capacity: append never invokes Go's geometric slice growth.
type outputBuffer struct {
	bytes []byte
	limit int
}

func newOutputBuffer(limit int) *outputBuffer { return &outputBuffer{make([]byte, 0, limit), limit} }
func (b *outputBuffer) append(s string) error {
	if len(s) > b.limit-len(b.bytes) {
		return ErrOutputTooLarge
	}
	b.bytes = append(b.bytes, s...)
	return nil
}
func failure(ctx context.Context, fallback error) error {
	if cause := context.Cause(ctx); cause != nil {
		return cause
	}
	return fallback
}

// optionalFieldBlamed reports whether a rejected request named one of the
// optional extension fields (response_format, chat_template_kwargs) in its
// (capped) error body — the trigger for one field-free retry.
func optionalFieldBlamed(body string) bool {
	b := strings.ToLower(body)
	return strings.Contains(b, "response_format") ||
		strings.Contains(b, "json_schema") || strings.Contains(b, "json schema") ||
		strings.Contains(b, "chat_template_kwargs") || strings.Contains(b, "enable_thinking")
}

// sizeRefusal reports a rejection for prompt size: 413, 507 (MTPLX's
// memory-plan refusal) or a 400/422/500 whose capped body names the context
// or token limit. The body is only inspected, never logged.
func sizeRefusal(status int, body string) bool {
	if status == 413 || status == 507 {
		return true
	}
	if status != 400 && status != 422 && status != 500 {
		return false
	}
	b := strings.ToLower(body)
	for _, w := range []string{"context", "too long", "too large", "maximum", "max_tokens", "token limit", "memory"} {
		if strings.Contains(b, w) {
			return true
		}
	}
	return false
}

func (a *OpenAI) Generate(parent context.Context, in Input) (Completion, error) {
	// Rewriting asks for at most 64 KiB; an analysis result line may be 96 KiB
	// (analysis.MaxLineBytes). A caller above the ceiling is a programming error.
	if in.MaxOutputBytes < 1 || in.MaxOutputBytes > MaxOutputBytes {
		return Completion{}, fmt.Errorf("%w: output_cap_%d", ErrBackend, in.MaxOutputBytes)
	}
	start := time.Now()
	timeout, firstToken := a.config.Timeout, a.config.FirstTokenTimeout
	if in.Timeout > 0 {
		timeout = in.Timeout
	}
	if in.FirstTokenTimeout > 0 {
		firstToken = in.FirstTokenTimeout
	}
	ctx, timeoutCancel := context.WithTimeoutCause(parent, timeout, ErrTimeout)
	defer timeoutCancel()
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(context.Canceled)
	firstTimer := time.AfterFunc(firstToken, func() { cancel(ErrFirstTokenTimeout) })
	defer firstTimer.Stop()
	if a.config.DebugDelay > 0 {
		timer := time.NewTimer(a.config.DebugDelay)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-ctx.Done():
			return Completion{}, context.Cause(ctx)
		}
	}
	payload := map[string]any{"model": a.config.Model, "stream": true, "temperature": 0}
	if in.Temperature != nil {
		payload["temperature"] = *in.Temperature
	}
	if in.ResponseSchema != nil {
		payload["response_format"] = in.ResponseSchema
	}
	if in.ReasoningOff {
		payload["chat_template_kwargs"] = map[string]any{"enable_thinking": false}
	}
	if in.MaxOutputTokens > 0 {
		payload["max_tokens"] = in.MaxOutputTokens
	}
	messages := []map[string]string{{"role": "system", "content": in.System}, {"role": "user", "content": in.Text}}
	if in.Followup != "" {
		messages = append(messages, map[string]string{"role": "user", "content": in.Followup})
	}
	payload["messages"] = messages
	var rejectedBody string
	send := func() (*http.Response, error) {
		body, err := json.Marshal(payload)
		if err != nil {
			return nil, ErrBackend
		}
		req, err := http.NewRequestWithContext(ctx, "POST", a.config.BaseURL+"/chat/completions", bytes.NewReader(body))
		if err != nil {
			return nil, ErrBackend
		}
		if a.config.Token != "" {
			req.Header.Set("Authorization", "Bearer "+a.config.Token)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "text/event-stream")
		resp, err := a.client.Do(req)
		if err != nil {
			return nil, failure(ctx, ErrUnavailable)
		}
		if resp.StatusCode == http.StatusOK {
			return resp, nil
		}
		errBody, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrorBody))
		_ = resp.Body.Close()
		rejectedBody = string(errBody)
		code := ErrBackend
		if resp.StatusCode == 503 || resp.StatusCode == 502 {
			code = ErrUnavailable
		}
		if sizeRefusal(resp.StatusCode, rejectedBody) && !optionalFieldBlamed(rejectedBody) {
			code = ErrTooLarge
		}
		// The status alone, never the body: enough to tell a rejected request from
		// a backend that is down, without logging what was sent.
		return nil, failure(ctx, fmt.Errorf("%w: http_%d", code, resp.StatusCode))
	}
	resp, err := send()
	schemaAccepted := in.ResponseSchema != nil
	if err != nil && (schemaAccepted || in.ReasoningOff) && optionalFieldBlamed(rejectedBody) {
		// A backend that cannot honour response_format or chat_template_kwargs
		// gets the same request once more without them; the in-prompt schema
		// still guides its output.
		delete(payload, "response_format")
		delete(payload, "chat_template_kwargs")
		schemaAccepted = false
		resp, err = send()
	}
	if err != nil {
		return Completion{}, err
	}
	defer resp.Body.Close()
	output := newOutputBuffer(in.MaxOutputBytes)
	result := Completion{Model: boundModel(a.config.Model), SchemaAccepted: schemaAccepted}
	done := false
	// Scanner has a fixed backing buffer: a line larger than the limit fails
	// before any larger buffer is allocated, even without a newline.
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, maxSSELine+2), maxSSELine+2)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) > maxSSELine {
			cancel(ErrBackend)
			return Completion{}, ErrBackend
		}
		if len(line) == 0 || line[0] == ':' {
			continue
		}
		if !bytes.HasPrefix(line, []byte("data:")) {
			continue
		}
		data := bytes.TrimSpace(line[5:])
		if bytes.Equal(data, []byte("[DONE]")) {
			done = true
			break
		}
		var event struct {
			Model   string
			Choices []struct {
				Delta        struct{ Content string }
				FinishReason *string `json:"finish_reason"`
			}
			Error json.RawMessage
		}
		if json.Unmarshal(data, &event) != nil {
			return Completion{}, fmt.Errorf("%w: sse_malformed", ErrBackend)
		}
		if len(event.Error) > 0 {
			return Completion{}, fmt.Errorf("%w: sse_error_event", ErrBackend)
		}
		if event.Choices == nil {
			return Completion{}, fmt.Errorf("%w: sse_no_choices", ErrBackend)
		}
		if event.Model != "" {
			if event.Model != a.config.Model {
				return Completion{}, fmt.Errorf("%w: model_mismatch", ErrBackend)
			}
			result.Model = boundModel(event.Model)
		}
		for _, choice := range event.Choices {
			fragment := choice.Delta.Content
			if choice.FinishReason != nil && *choice.FinishReason != "stop" && *choice.FinishReason != "length" {
				return Completion{}, fmt.Errorf("%w: finish_%s", ErrBackend, *choice.FinishReason)
			}
			if choice.FinishReason != nil && *choice.FinishReason == "length" {
				result.Truncated = true
			}
			if fragment == "" {
				continue
			}
			if result.FirstTokenMS == nil {
				firstTimer.Stop()
				ms := int(time.Since(start).Milliseconds())
				result.FirstTokenMS = &ms
			}
			if ctx.Err() != nil {
				return Completion{}, context.Cause(ctx)
			}
			if err := output.append(fragment); err != nil {
				cancel(err)
				_ = resp.Body.Close()
				return Completion{}, err
			}
			if in.Progress != nil {
				if err := in.Progress(utf8.RuneCount(output.bytes)); err != nil {
					cancel(err)
					return Completion{}, err
				}
			}
		}
	}
	if ctx.Err() != nil {
		return Completion{}, context.Cause(ctx)
	}
	// A truncated stream may end without [DONE] — the server already
	// reported the finish, so the partial text stands on its own.
	if scanner.Err() != nil || (!done && !result.Truncated) {
		return Completion{}, failure(ctx, ErrBackend)
	}
	result.Text = string(output.bytes)
	result.DurationMS = int(time.Since(start).Milliseconds())
	return result, nil
}
