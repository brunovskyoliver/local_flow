// Package rewrite implements the LocalFlow rewrite protocol v1 types and their
// validation. The wire contract is specs/003-server-rewriting/contracts/rewrite-protocol.md.
package rewrite

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"
)

// Limits shared with the client; enforced on raw bytes before parsing.
const (
	SchemaVersion       = 1
	ServiceName         = "localflow-rewrite"
	MaxRequestBodyBytes = 262144
	MaxInputScalars     = 20000
	MaxInputBytes       = 65536
	MaxLineBytes        = 8192
	MaxLanguageHints    = 4
	MaxIdentityBytes    = 128
)

// ErrorCode is one of the contract's error codes.
type ErrorCode string

const (
	CodeInvalidRequest           ErrorCode = "invalid_request"
	CodeUnsupportedVersion       ErrorCode = "unsupported_version"
	CodeUnauthorized             ErrorCode = "unauthorized"
	CodeTooLarge                 ErrorCode = "too_large"
	CodeBackendUnavailable       ErrorCode = "backend_unavailable"
	CodeBackendTimeout           ErrorCode = "backend_timeout"
	CodeBackendFirstTokenTimeout ErrorCode = "backend_first_token_timeout"
	CodeBackendError             ErrorCode = "backend_error"
	CodeOutputTooLarge           ErrorCode = "output_too_large"
	CodeShieldRestoreFailed      ErrorCode = "shield_restore_failed"
	CodeServerBusy               ErrorCode = "server_busy"
)

// Modes a request may name. "exact" never produces a request.
var Modes = []string{"clean", "polished", "concise"}

// Request is the body of POST /v1/rewrite. Unknown fields are rejected.
type Request struct {
	SchemaVersion int      `json:"schema_version"`
	RequestID     string   `json:"request_id"`
	Mode          string   `json:"mode"`
	Text          string   `json:"text"`
	LanguageHints []string `json:"language_hints"`
	StreamDeltas  bool     `json:"stream_deltas"`
}

// InputBytes is the UTF-8 length of the text; the output bound derives from it.
func (r Request) InputBytes() int { return len(r.Text) }

// MaxOutputBytes is min(4 x input bytes, 65,536): the bound the server applies
// per streamed fragment and the client applies to result.text.
func (r Request) MaxOutputBytes() int {
	n := 4 * r.InputBytes()
	if n > MaxInputBytes {
		return MaxInputBytes
	}
	return n
}

// RequestError carries the code a rejected request maps to.
type RequestError struct {
	Code   ErrorCode
	Reason string
}

func (e *RequestError) Error() string { return string(e.Code) + ": " + e.Reason }

// DecodeRequest reads at most MaxRequestBodyBytes+1 bytes and validates every
// field. It never logs or returns the text.
func DecodeRequest(r io.Reader) (Request, error) {
	var req Request
	limited := io.LimitReader(r, MaxRequestBodyBytes+1)
	body, err := io.ReadAll(limited)
	if err != nil {
		return req, &RequestError{CodeInvalidRequest, "body unreadable"}
	}
	if len(body) > MaxRequestBodyBytes {
		return req, &RequestError{CodeTooLarge, "body over limit"}
	}
	if !utf8.Valid(body) {
		return req, &RequestError{CodeInvalidRequest, "body not UTF-8"}
	}
	// Type checks happen on the raw object so a wrong-typed field is rejected
	// rather than zero-valued.
	var raw map[string]json.RawMessage
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	if err := dec.Decode(&raw); err != nil {
		return req, &RequestError{CodeInvalidRequest, "not a JSON object"}
	}
	if dec.More() {
		return req, &RequestError{CodeInvalidRequest, "trailing data"}
	}
	allowed := map[string]bool{
		"schema_version": true, "request_id": true, "mode": true, "text": true,
		"language_hints": true, "stream_deltas": true,
	}
	for key := range raw {
		if !allowed[key] {
			return req, &RequestError{CodeInvalidRequest, "unknown field"}
		}
	}
	for key := range allowed {
		if _, ok := raw[key]; !ok {
			return req, &RequestError{CodeInvalidRequest, "missing field " + key}
		}
	}
	// json.Number also accepts a quoted string, so require a bare number literal.
	var version json.Number
	trimmed := bytes.TrimSpace(raw["schema_version"])
	if len(trimmed) == 0 || trimmed[0] == '"' || json.Unmarshal(trimmed, &version) != nil {
		return req, &RequestError{CodeUnsupportedVersion, "schema_version not a number"}
	}
	if v, err := version.Int64(); err != nil || v != SchemaVersion {
		return req, &RequestError{CodeUnsupportedVersion, "schema_version unsupported"}
	}
	req.SchemaVersion = SchemaVersion
	if err := json.Unmarshal(raw["request_id"], &req.RequestID); err != nil || !IsUUID(req.RequestID) {
		return req, &RequestError{CodeInvalidRequest, "request_id not a UUID"}
	}
	if err := json.Unmarshal(raw["mode"], &req.Mode); err != nil || !validMode(req.Mode) {
		return req, &RequestError{CodeInvalidRequest, "mode invalid"}
	}
	if err := json.Unmarshal(raw["text"], &req.Text); err != nil {
		return req, &RequestError{CodeInvalidRequest, "text not a string"}
	}
	if strings.TrimSpace(req.Text) == "" {
		return req, &RequestError{CodeInvalidRequest, "text blank"}
	}
	if len(req.Text) > MaxInputBytes {
		return req, &RequestError{CodeTooLarge, "text over byte limit"}
	}
	if !utf8.ValidString(req.Text) {
		return req, &RequestError{CodeInvalidRequest, "text not UTF-8"}
	}
	if utf8.RuneCountInString(req.Text) > MaxInputScalars {
		return req, &RequestError{CodeTooLarge, "text over scalar limit"}
	}
	if err := json.Unmarshal(raw["language_hints"], &req.LanguageHints); err != nil || req.LanguageHints == nil {
		return req, &RequestError{CodeInvalidRequest, "language_hints not an array"}
	}
	if len(req.LanguageHints) > MaxLanguageHints {
		return req, &RequestError{CodeInvalidRequest, "too many language hints"}
	}
	for _, hint := range req.LanguageHints {
		if hint == "" || len(hint) > 35 {
			return req, &RequestError{CodeInvalidRequest, "language hint invalid"}
		}
	}
	if value := string(bytes.TrimSpace(raw["stream_deltas"])); value != "true" && value != "false" {
		return req, &RequestError{CodeInvalidRequest, "stream_deltas not a boolean"}
	}
	if err := json.Unmarshal(raw["stream_deltas"], &req.StreamDeltas); err != nil {
		return req, &RequestError{CodeInvalidRequest, "stream_deltas not a boolean"}
	}
	return req, nil
}

func validMode(mode string) bool {
	for _, m := range Modes {
		if m == mode {
			return true
		}
	}
	return false
}

// IsUUID accepts the canonical 8-4-4-4-12 hexadecimal form in either case.
func IsUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			isHex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
			if !isHex {
				return false
			}
		}
	}
	return true
}

// Identity names the server that produced a result.
type Identity struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

// Backend names the adapter and the model it reported.
type Backend struct {
	Kind  string `json:"kind"`
	Model string `json:"model"`
}

// Shield reports the placeholder round trip; result is sent only when equal.
type Shield struct {
	Version      int `json:"version"`
	Placeholders int `json:"placeholders"`
	Restored     int `json:"restored"`
}

// Timing holds server spans in milliseconds; an unmeasured span is omitted, never zero.
type Timing struct {
	QueueMs             *int `json:"queue_ms,omitempty"`
	BackendFirstTokenMs *int `json:"backend_first_token_ms,omitempty"`
	BackendMs           *int `json:"backend_ms,omitempty"`
}

// Result is the terminal success event.
type Result struct {
	Event         string   `json:"event"`
	SchemaVersion int      `json:"schema_version"`
	RequestID     string   `json:"request_id"`
	Mode          string   `json:"mode"`
	Text          string   `json:"text"`
	Unchanged     bool     `json:"unchanged"`
	Server        Identity `json:"server"`
	Backend       Backend  `json:"backend"`
	PromptVersion int      `json:"prompt_version"`
	Shield        Shield   `json:"shield"`
	Timing        Timing   `json:"timing"`
}

// Event is one NDJSON line. Exactly one of the typed payloads is used per kind.
type Event struct {
	Event          string    `json:"event"`
	RequestID      string    `json:"request_id"`
	GeneratedChars *int      `json:"generated_chars,omitempty"`
	Text           *string   `json:"text,omitempty"`
	Code           ErrorCode `json:"code,omitempty"`
	Message        string    `json:"message,omitempty"`
}

// Accepted, Progress, Delta and Error build the non-result events.
func Accepted(id string) Event { return Event{Event: "accepted", RequestID: id} }
func Progress(id string, chars int) Event {
	return Event{Event: "progress", RequestID: id, GeneratedChars: &chars}
}
func Delta(id, text string) Event { return Event{Event: "delta", RequestID: id, Text: &text} }
func Error(id string, code ErrorCode, message string) Event {
	return Event{Event: "error", RequestID: id, Code: code, Message: message}
}

// NewResult fills the constant fields of a result event.
func NewResult(req Request, text string, server Identity, backend Backend, promptVersion int, shield Shield, timing Timing) Result {
	return Result{
		Event: "result", SchemaVersion: SchemaVersion, RequestID: req.RequestID, Mode: req.Mode,
		Text: text, Unchanged: text == req.Text, Server: server, Backend: backend,
		PromptVersion: promptVersion, Shield: shield, Timing: timing,
	}
}

// ErrLineTooLong is returned when a non-result event exceeds MaxLineBytes.
var ErrLineTooLong = errors.New("rewrite: event line over limit")

// EncodeLine serializes one event with its trailing newline and enforces the
// per-line bound for everything except result.
func EncodeLine(v any) ([]byte, error) {
	data, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	if _, isResult := v.(Result); !isResult && len(data)+1 > MaxLineBytes {
		return nil, ErrLineTooLong
	}
	return append(data, '\n'), nil
}

// Health is the body of GET /v1/rewrite/health.
type Health struct {
	SchemaVersion    int            `json:"schema_version"`
	Service          string         `json:"service"`
	ProtocolVersions []int          `json:"protocol_versions"`
	Server           Identity       `json:"server"`
	Modes            []string       `json:"modes"`
	Backend          HealthBackend  `json:"backend"`
	PromptVersions   map[string]int `json:"prompt_versions"`
	ShieldVersion    int            `json:"shield_version"`
}

// HealthBackend reports the cached backend probe.
type HealthBackend struct {
	State string `json:"state"`
	Kind  string `json:"kind"`
	Model string `json:"model"`
}

// ErrorBody is the JSON body of a non-200 response.
type ErrorBody struct {
	Error struct {
		Code    ErrorCode `json:"code"`
		Message string    `json:"message"`
	} `json:"error"`
}

// NewErrorBody builds the non-200 body.
func NewErrorBody(code ErrorCode, message string) ErrorBody {
	var body ErrorBody
	body.Error.Code = code
	body.Error.Message = message
	return body
}

// BoundIdentity truncates an identity string to the contract's byte limit at a
// rune boundary, so a long backend model id never breaks the client's check.
func BoundIdentity(s string) string {
	if len(s) <= MaxIdentityBytes {
		return s
	}
	cut := MaxIdentityBytes
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut]
}

// String renders the error code for logs; never the message or text.
func (c ErrorCode) String() string { return fmt.Sprintf("%s", string(c)) }
