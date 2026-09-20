// Package analysis implements the LocalFlow meeting analysis protocol v1
// (specs/011-meeting-intelligence/contracts/analysis-protocol.md): request,
// result, event and health types with strict decoding and every field rule of
// the contract table.
package analysis

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"time"
)

const (
	SchemaVersion       = 1
	ServiceName         = "localflow-analysis"
	MaxRequestBodyBytes = 262144
	// MaxLineBytes bounds one NDJSON response line, including the result line.
	MaxLineBytes      = 98304
	MaxIdentityBytes  = 128
	MaxTitleBytes     = 256
	MaxTimeZoneBytes  = 64
	MaxNameBytes      = 80
	MaxOriginBytes    = 32
	MaxParticipants   = 64
	MaxSegments       = 4096
	MaxSegmentBytes   = 4096
	MaxNotes          = 256
	MaxNoteBytes      = 8192
	MaxPartials       = 16
	MaxChunks         = 64
	MaxSummaryBytes   = 4000
	MaxTopicTitle     = 200
	MaxTopicSummary   = 2000
	MaxTopicBullets   = 12
	MaxBulletBytes    = 500
	MaxItemText       = 1000
	MaxDueOriginal    = 80
	MaxSourcesPerItem = 10
)

// Code is one of the contract's error codes; a fixed one-sentence message is
// attached at write time, never backend text.
type Code string

const (
	CodeInvalidRequest           Code = "invalid_request"
	CodeUnsupportedVersion       Code = "unsupported_version"
	CodeUnauthorized             Code = "unauthorized"
	CodeTooLarge                 Code = "too_large"
	CodeServerBusy               Code = "server_busy"
	CodeQueueTimeout             Code = "queue_timeout"
	CodePreempted                Code = "preempted"
	CodeBackendUnavailable       Code = "backend_unavailable"
	CodeBackendTimeout           Code = "backend_timeout"
	CodeBackendFirstTokenTimeout Code = "backend_first_token_timeout"
	CodeBackendError             Code = "backend_error"
	CodeOutputTooLarge           Code = "output_too_large"
	CodeOutputInvalid            Code = "output_invalid"
	CodeSourceValidation         Code = "source_validation"
)

// RequestError carries the wire code of a rejected request.
type RequestError struct {
	Code   Code
	Reason string
}

func (e *RequestError) Error() string { return fmt.Sprintf("%s: %s", e.Code, e.Reason) }

func invalid(reason string) *RequestError { return &RequestError{CodeInvalidRequest, reason} }

// Stages.
const (
	StageFull      = "full"
	StageChunk     = "chunk"
	StageSynthesis = "synthesis"
)

// Participant certainties; only the named set may carry `name`.
var nameCertainties = map[string]bool{
	"confirmed": true, "recognized": true, "local_name": true, "local_user": true,
}
var knownSpeakerCertainties = map[string]bool{
	"confirmed": true, "recognized": true,
}
var certainties = map[string]bool{
	"confirmed": true, "recognized": true, "possible": true, "unknown": true,
	"local_name": true, "local_user": true,
}

type Chunk struct {
	Index int `json:"index"`
	Count int `json:"count"`
}

type LanguagePolicy struct {
	Output        string `json:"output"`
	PreserveTerms bool   `json:"preserve_terms"`
}

type Meeting struct {
	ID             string         `json:"id"`
	Title          string         `json:"title"`
	StartedAt      string         `json:"started_at"`
	DurationMS     int64          `json:"duration_ms"`
	TimeZone       string         `json:"time_zone"`
	LanguagePolicy LanguagePolicy `json:"language_policy"`
}

type Participant struct {
	SpeakerID      string  `json:"speaker_id"`
	Certainty      string  `json:"certainty"`
	Origin         string  `json:"origin"`
	KnownSpeakerID *string `json:"known_speaker_id"`
	Name           *string `json:"name"`
}

type Segment struct {
	ID        string  `json:"id"`
	StartMS   int64   `json:"start_ms"`
	EndMS     int64   `json:"end_ms"`
	SpeakerID *string `json:"speaker_id"`
	Text      string  `json:"text"`
}

type Note struct {
	ID   string `json:"id"`
	Text string `json:"text"`
}

// Request is the body of POST /v1/analysis/meeting.
type Request struct {
	SchemaVersion int           `json:"schema_version"`
	RequestID     string        `json:"request_id"`
	RunID         string        `json:"run_id"`
	Priority      string        `json:"priority"`
	Stage         string        `json:"stage"`
	Chunk         *Chunk        `json:"chunk"`
	Meeting       Meeting       `json:"meeting"`
	Participants  []Participant `json:"participants"`
	Segments      []Segment     `json:"segments"`
	Notes         []Note        `json:"notes"`
	Partials      []Analysis    `json:"partials"`
}

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func isUUID(s string) bool { return uuidPattern.MatchString(s) }

var noteIDPattern = regexp.MustCompile(`^note:([1-9][0-9]*)$`)

// DecodeRequest reads at most MaxRequestBodyBytes+1 bytes and applies every
// field rule of the contract table. `inputLimit` is the configured
// --analysis-input-bytes bound on summed text.
func DecodeRequest(body io.Reader, inputLimit int) (*Request, error) {
	data, err := io.ReadAll(io.LimitReader(body, MaxRequestBodyBytes+1))
	if err != nil {
		return nil, &RequestError{CodeTooLarge, "unreadable body"}
	}
	return DecodeRequestBytes(data, inputLimit)
}

// DecodeRequestBytes validates an already-read body.
func DecodeRequestBytes(data []byte, inputLimit int) (*Request, error) {
	if len(data) > MaxRequestBodyBytes {
		return nil, &RequestError{CodeTooLarge, "body over 262144 bytes"}
	}
	var req Request
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		return nil, invalid("malformed JSON or unknown field")
	}
	if decoder.More() {
		return nil, invalid("trailing data")
	}
	return &req, req.validate(inputLimit)
}

func (r *Request) validate(inputLimit int) error {
	if r.SchemaVersion != SchemaVersion {
		return &RequestError{CodeUnsupportedVersion, "schema_version must be 1"}
	}
	if !isUUID(r.RequestID) || !isUUID(r.RunID) {
		return invalid("request_id and run_id must be UUIDs")
	}
	if r.Priority != "background" {
		return invalid("priority must be background")
	}
	switch r.Stage {
	case StageFull, StageChunk, StageSynthesis:
	default:
		return invalid("unknown stage")
	}
	if r.Stage == StageChunk {
		if r.Chunk == nil || r.Chunk.Index < 0 || r.Chunk.Count < 1 ||
			r.Chunk.Index >= r.Chunk.Count || r.Chunk.Count > MaxChunks {
			return invalid("chunk requires index < count <= 64")
		}
	} else if r.Chunk != nil {
		return invalid("chunk is only present for stage=chunk")
	}
	if !isUUID(r.Meeting.ID) {
		return invalid("meeting.id must be a UUID")
	}
	if len(r.Meeting.Title) > MaxTitleBytes {
		return invalid("meeting.title over 256 bytes")
	}
	// RFC 3339 requires an explicit offset; time.Parse rejects a missing one.
	if _, err := time.Parse(time.RFC3339, r.Meeting.StartedAt); err != nil {
		return invalid("meeting.started_at must be RFC 3339")
	}
	if r.Meeting.DurationMS < 0 {
		return invalid("meeting.duration_ms must be >= 0")
	}
	if r.Meeting.TimeZone == "" || len(r.Meeting.TimeZone) > MaxTimeZoneBytes {
		return invalid("meeting.time_zone must be an IANA name <= 64 bytes")
	}
	if _, err := time.LoadLocation(r.Meeting.TimeZone); err != nil {
		return invalid("meeting.time_zone must be an IANA name")
	}
	switch r.Meeting.LanguagePolicy.Output {
	case "sk", "en", "mixed":
	default:
		return invalid("language_policy.output must be sk, en or mixed")
	}
	if len(r.Participants) > MaxParticipants {
		return invalid("participants over 64")
	}
	speakers := map[string]bool{}
	for _, p := range r.Participants {
		if !isUUID(p.SpeakerID) {
			return invalid("participant speaker_id must be a UUID")
		}
		if speakers[p.SpeakerID] {
			return invalid("participant speaker_id must be unique")
		}
		speakers[p.SpeakerID] = true
		if !certainties[p.Certainty] {
			return invalid("unknown certainty")
		}
		if p.Name != nil {
			if !nameCertainties[p.Certainty] {
				return invalid("name only with a named certainty")
			}
			if len(*p.Name) < 1 || len(*p.Name) > MaxNameBytes {
				return invalid("participant name must be 1..80 bytes")
			}
		}
		if p.KnownSpeakerID != nil &&
			(!knownSpeakerCertainties[p.Certainty] || !isUUID(*p.KnownSpeakerID)) {
			return invalid("known_speaker_id only with confirmed or recognized")
		}
		if len(p.Origin) > MaxOriginBytes {
			return invalid("origin over 32 bytes")
		}
	}
	textBytes := 0
	switch r.Stage {
	case StageFull, StageChunk:
		if len(r.Segments) < 1 || len(r.Segments) > MaxSegments {
			return invalid("segments required for full and chunk")
		}
	case StageSynthesis:
		if r.Segments != nil {
			return invalid("segments absent for synthesis")
		}
		if len(r.Partials) < 1 || len(r.Partials) > MaxPartials {
			return invalid("synthesis requires 1..16 partials")
		}
	}
	if r.Stage != StageSynthesis && r.Partials != nil {
		return invalid("partials only for synthesis")
	}
	seenSegments := map[string]bool{}
	for _, s := range r.Segments {
		if !isUUID(s.ID) {
			return invalid("segment id must be a UUID")
		}
		if seenSegments[s.ID] {
			return invalid("segment ids must be unique")
		}
		seenSegments[s.ID] = true
		if s.EndMS < s.StartMS {
			return invalid("segment end_ms must be >= start_ms")
		}
		if s.SpeakerID != nil && !speakers[*s.SpeakerID] {
			return invalid("segment speaker_id must name a participant")
		}
		if len(s.Text) < 1 || len(s.Text) > MaxSegmentBytes {
			return invalid("segment text must be 1..4096 bytes")
		}
		textBytes += len(s.Text)
	}
	if r.Stage == StageChunk && r.Notes != nil {
		return invalid("notes only for full and synthesis")
	}
	if len(r.Notes) > MaxNotes {
		return invalid("notes over 256")
	}
	lastNote := 0
	for _, n := range r.Notes {
		match := noteIDPattern.FindStringSubmatch(n.ID)
		if match == nil {
			return invalid("note ids are note:<n>")
		}
		var ordinal int
		fmt.Sscanf(match[1], "%d", &ordinal)
		if ordinal <= lastNote {
			return invalid("note ids strictly increasing")
		}
		lastNote = ordinal
		if len(n.Text) < 1 || len(n.Text) > MaxNoteBytes {
			return invalid("note text must be 1..8192 bytes")
		}
		textBytes += len(n.Text)
	}
	for _, p := range r.Partials {
		encoded, _ := json.Marshal(p)
		textBytes += len(encoded)
	}
	if textBytes > inputLimit {
		return &RequestError{CodeTooLarge, "input text over the configured limit"}
	}
	return nil
}

// --- Result object (analysis) ---

type SourceRef struct {
	Kind string `json:"kind"`
	ID   string `json:"id"`
}

type Summary struct {
	Text         string      `json:"text"`
	Sources      []SourceRef `json:"sources"`
	WholeMeeting bool        `json:"whole_meeting"`
}

type Topic struct {
	Title   string      `json:"title"`
	Summary string      `json:"summary"`
	Bullets []string    `json:"bullets"`
	Sources []SourceRef `json:"sources"`
}

type Item struct {
	Text          string      `json:"text"`
	EvidenceClass *string     `json:"evidence_class"`
	Sources       []SourceRef `json:"sources"`
}

type Owner struct {
	Kind      string  `json:"kind"`
	SpeakerID *string `json:"speaker_id"`
	Name      *string `json:"name"`
}

type Due struct {
	State    string     `json:"state"`
	Date     *string    `json:"date"`
	Original *string    `json:"original"`
	Source   *SourceRef `json:"source"`
}

type ActionItem struct {
	Text           string      `json:"text"`
	Owner          Owner       `json:"owner"`
	OwnershipState string      `json:"ownership_state"`
	Due            Due         `json:"due"`
	Sources        []SourceRef `json:"sources"`
}

// Analysis is the `analysis` object of a `result` event; `partials` in a
// synthesis request carry the same shape.
type Analysis struct {
	SchemaVersion int          `json:"schema_version"`
	MeetingID     string       `json:"meeting_id"`
	Partial       bool         `json:"partial"`
	Language      string       `json:"language"`
	Summary       Summary      `json:"summary"`
	Topics        []Topic      `json:"topics"`
	Decisions     []Item       `json:"decisions"`
	ActionItems   []ActionItem `json:"action_items"`
	NextSteps     []Item       `json:"next_steps"`
	OpenQuestions []Item       `json:"open_questions"`
	Risks         []Item       `json:"risks"`
}

// --- Events ---

type Identity struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

type BackendInfo struct {
	Kind  string `json:"kind"`
	Model string `json:"model"`
}

type Timing struct {
	QueueMS      *int `json:"queue_ms"`
	FirstTokenMS *int `json:"first_token_ms"`
	BackendMS    *int `json:"backend_ms"`
}

type AcceptedEvent struct {
	SchemaVersion int      `json:"schema_version"`
	Type          string   `json:"type"`
	RequestID     string   `json:"request_id"`
	Server        Identity `json:"server"`
}

type ProgressEvent struct {
	SchemaVersion int    `json:"schema_version"`
	Type          string `json:"type"`
	RequestID     string `json:"request_id"`
	Stage         string `json:"stage"`
	Chars         int    `json:"chars"`
}

type ResultEvent struct {
	SchemaVersion   int         `json:"schema_version"`
	Type            string      `json:"type"`
	RequestID       string      `json:"request_id"`
	RunID           string      `json:"run_id"`
	Stage           string      `json:"stage"`
	Server          Identity    `json:"server"`
	Backend         BackendInfo `json:"backend"`
	PromptVersion   int         `json:"prompt_version"`
	PipelineVersion string      `json:"pipeline_version"`
	Timing          Timing      `json:"timing"`
	Preemptions     int         `json:"preemptions"`
	Analysis        Analysis    `json:"analysis"`
}

type ErrorEvent struct {
	SchemaVersion int    `json:"schema_version"`
	Type          string `json:"type"`
	RequestID     string `json:"request_id"`
	Code          Code   `json:"code"`
	Message       string `json:"message"`
}

func Accepted(requestID string) AcceptedEvent {
	return AcceptedEvent{SchemaVersion, "accepted", requestID, Identity{"flowd", ServerVersion}}
}

func Progress(requestID, stage string, chars int) ProgressEvent {
	return ProgressEvent{SchemaVersion, "progress", requestID, stage, chars}
}

func Error(requestID string, code Code) ErrorEvent {
	return ErrorEvent{SchemaVersion, "error", requestID, code, Message(code)}
}

// Message is the fixed one-sentence text per code; never backend output.
func Message(code Code) string {
	switch code {
	case CodeUnauthorized:
		return "Authentication failed."
	case CodeTooLarge:
		return "The request exceeds the size limit."
	case CodeServerBusy:
		return "An analysis is already running."
	case CodeQueueTimeout:
		return "The server is busy with dictation."
	case CodePreempted:
		return "The analysis was preempted by dictation."
	case CodeBackendUnavailable:
		return "The language model backend is not running."
	case CodeBackendTimeout, CodeBackendFirstTokenTimeout:
		return "The language model backend timed out."
	case CodeUnsupportedVersion:
		return "The protocol version is unsupported."
	case CodeInvalidRequest:
		return "The analysis request is invalid."
	case CodeOutputTooLarge:
		return "The model output exceeded the size limit."
	case CodeOutputInvalid:
		return "The model output failed validation."
	case CodeSourceValidation:
		return "The model output references unknown sources."
	default:
		return "The analysis failed."
	}
}

// ErrorBody is the JSON body of a non-200 response.
type ErrorBody struct {
	Error struct {
		Code    Code   `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func NewErrorBody(code Code) ErrorBody {
	var body ErrorBody
	body.Error.Code = code
	body.Error.Message = Message(code)
	return body
}

// Health is the body of GET /v1/analysis/health.
type Health struct {
	SchemaVersion    int            `json:"schema_version"`
	Service          string         `json:"service"`
	ProtocolVersions []int          `json:"protocol_versions"`
	Server           Identity       `json:"server"`
	Backend          HealthBackend  `json:"backend"`
	PromptVersions   map[string]int `json:"prompt_versions"`
	ResultSchema     int            `json:"result_schema_version"`
	Limits           HealthLimits   `json:"limits"`
	Caps             HealthCaps     `json:"caps"`
}

type HealthBackend struct {
	State      string `json:"state"`
	Kind       string `json:"kind"`
	Model      string `json:"model"`
	JSONSchema bool   `json:"json_schema"`
}

type HealthLimits struct {
	InputBytes    int `json:"input_bytes"`
	OutputBytes   int `json:"output_bytes"`
	ContextTokens int `json:"context_tokens"`
	Concurrency   int `json:"concurrency"`
}

type HealthCaps struct {
	SourcesPerItem int `json:"sources_per_item"`
	Topics         int `json:"topics"`
	Decisions      int `json:"decisions"`
	ActionItems    int `json:"action_items"`
	NextSteps      int `json:"next_steps"`
	OpenQuestions  int `json:"open_questions"`
	Risks          int `json:"risks"`
}

const ServerVersion = "0.3.0"
