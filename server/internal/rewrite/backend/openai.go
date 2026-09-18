// Package backend talks to a separately supervised inference process. It owns
// no model weights and never exposes backend error bodies to callers or logs.
package backend

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"localflow/server/internal/rewrite/prompts"
)

var (
	ErrOutputTooLarge    = errors.New("output_too_large")
	ErrFirstTokenTimeout = errors.New("backend_first_token_timeout")
	ErrTimeout           = errors.New("backend_timeout")
	ErrUnavailable       = errors.New("backend_unavailable")
	ErrBackend           = errors.New("backend_error")
)

const maxSSELine = 65536
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
	System, Text   string
	MaxOutputBytes int
	JSONSchema     bool
	Progress       func(int) error
}
type Completion struct {
	Text, Model  string
	FirstTokenMS *int
	DurationMS   int
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
	tr.ResponseHeaderTimeout = c.Timeout
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
func (a *OpenAI) Generate(parent context.Context, in Input) (Completion, error) {
	if in.MaxOutputBytes < 1 || in.MaxOutputBytes > 65536 {
		return Completion{}, ErrBackend
	}
	start := time.Now()
	ctx, timeoutCancel := context.WithTimeoutCause(parent, a.config.Timeout, ErrTimeout)
	defer timeoutCancel()
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(context.Canceled)
	firstTimer := time.AfterFunc(a.config.FirstTokenTimeout, func() { cancel(ErrFirstTokenTimeout) })
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
	system := in.System
	payload := map[string]any{"model": a.config.Model, "stream": true, "temperature": 0}
	if in.JSONSchema {
		payload["response_format"] = prompts.ResponseFormat()
		system += prompts.ConstrainedInstruction
	}
	payload["messages"] = []map[string]string{{"role": "system", "content": system}, {"role": "user", "content": in.Text}}
	body, err := json.Marshal(payload)
	if err != nil {
		return Completion{}, ErrBackend
	}
	req, err := http.NewRequestWithContext(ctx, "POST", a.config.BaseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return Completion{}, ErrBackend
	}
	if a.config.Token != "" {
		req.Header.Set("Authorization", "Bearer "+a.config.Token)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	resp, err := a.client.Do(req)
	if err != nil {
		return Completion{}, failure(ctx, ErrUnavailable)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, maxErrorBody))
		code := ErrBackend
		if resp.StatusCode == 503 || resp.StatusCode == 502 {
			code = ErrUnavailable
		}
		return Completion{}, failure(ctx, code)
	}
	output := newOutputBuffer(in.MaxOutputBytes)
	result := Completion{Model: boundModel(a.config.Model)}
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
		if json.Unmarshal(data, &event) != nil || len(event.Error) > 0 || event.Choices == nil {
			return Completion{}, ErrBackend
		}
		if event.Model != "" {
			if event.Model != a.config.Model {
				return Completion{}, ErrBackend
			}
			result.Model = boundModel(event.Model)
		}
		for _, choice := range event.Choices {
			fragment := choice.Delta.Content
			if choice.FinishReason != nil && *choice.FinishReason != "stop" {
				return Completion{}, ErrBackend
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
	if scanner.Err() != nil || !done {
		return Completion{}, failure(ctx, ErrBackend)
	}
	result.Text = string(output.bytes)
	if in.JSONSchema {
		var decoded string
		if json.Unmarshal(output.bytes, &decoded) != nil {
			return Completion{}, ErrBackend
		}
		result.Text = decoded
	}
	result.DurationMS = int(time.Since(start).Milliseconds())
	return result, nil
}
