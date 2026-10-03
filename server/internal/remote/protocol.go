// Package remote implements flowd's remote channel v1: the loopback listener
// behind the owner's Cloudflare Tunnel, the HPKE-sealed WebSocket channel and
// its control messages. The wire contract is
// specs/014-remote-dictation-server/contracts/remote-channel.md with the
// additions in specs/018-one-server/contracts/remote-channel.md, and the JSON
// shapes are protocol/schemas/remote-*.schema.json.
package remote

import (
	"bytes"
	"crypto/ecdh"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"reflect"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Bounds shared with the client (contract and research R11).
const (
	SchemaVersion        = 1
	MaxControlBytes      = 65536
	MaxOp                = 1<<31 - 1
	WindowSamples        = 239360
	SampleRate           = 16000
	AudioFormat          = "f32le"
	MaxBoostTerms        = 256
	MaxGovernedSpellings = 1024
	MaxTermBytes         = 128
	MaxDeviceNameBytes   = 64
	DeviceKeyBytes       = 65
	KeyBytes             = 32
	MaxAudioSamples      = 16000
	MaxSessionSamples    = 2880000 + MaxAudioSamples
	MaxWindows           = 14
	maxIDTokenBytes      = 16384
	maxErrorMessageBytes = 256
	maxIdentityBytes     = 128
	maxTokens            = 16384
	maxRecognitionMS     = 600000
	maxExpiresIn         = 86400
)

// Feature 018 bounds (specs/018-one-server/contracts/remote-channel.md).
const (
	SampleFormat         = "s16le"
	MaxLiveSamples       = 96000
	MaxAnalysisPartBytes = 49152
	MaxAnalysisBytes     = 262144
	MaxAnalysisParts     = 64
	maxCapabilityOps     = 16
	maxVocabularyTerms   = 256
	maxSpeakers          = 64
	maxQueuePosition     = 1024
	maxTurns             = 20000
	maxClusters          = 256
	maxVectorLength      = 4096
	maxRetryDepth        = 2
)

// Meeting handoff bounds. A chunk is 48,000 bytes, not 49,152: base64url of
// 49,152 bytes alone fills the 65,536-byte control message.
const (
	MaxHandoffChunkBytes = 48000
	MaxHandoffFileBytes  = 1 << 30
	maxHandoffList       = 64
	maxHandoffDetail     = 64
)

// MeetingSamples is the sample_count range of each meeting job kind.
var MeetingSamples = map[string][2]int{
	"transcribe": {1, 1920000},
	"diarize":    {1, 9600000},
	"embed":      {48000, 320000},
}

// ErrorCode is one of the channel contract's error codes.
type ErrorCode string

const (
	CodeUnauthorized       ErrorCode = "unauthorized"
	CodeTokenExpired       ErrorCode = "token_expired"
	CodeNotApproved        ErrorCode = "not_approved"
	CodeRevoked            ErrorCode = "revoked"
	CodeBusy               ErrorCode = "busy"
	CodeInvalidMessage     ErrorCode = "invalid_message"
	CodeUnsupportedVersion ErrorCode = "unsupported_version"
	CodeLimitExceeded      ErrorCode = "limit_exceeded"
	CodeWorkerUnavailable  ErrorCode = "worker_unavailable"
	CodeInternal           ErrorCode = "internal"
	CodeNotOffered         ErrorCode = "not_offered"
)

// ErrorCodes lists every code in contract order.
var ErrorCodes = []ErrorCode{
	CodeUnauthorized, CodeTokenExpired, CodeNotApproved, CodeRevoked, CodeBusy,
	CodeInvalidMessage, CodeUnsupportedVersion, CodeLimitExceeded, CodeWorkerUnavailable, CodeInternal,
	CodeNotOffered,
}

var errorMessages = map[ErrorCode]string{
	CodeUnauthorized:       "The credentials were not accepted.",
	CodeTokenExpired:       "The access token has expired.",
	CodeNotApproved:        "The account or device is not approved yet.",
	CodeRevoked:            "The account or device was removed from the server.",
	CodeBusy:               "The server is busy.",
	CodeInvalidMessage:     "The message was not valid.",
	CodeUnsupportedVersion: "The protocol version is not supported.",
	CodeLimitExceeded:      "A size or length limit was exceeded.",
	CodeWorkerUnavailable:  "Speech recognition is unavailable on the server.",
	CodeInternal:           "The server could not complete the request.",
	CodeNotOffered:         "The server does not offer this operation.",
}

// Message is the fixed sentence sent with the code; it is never derived from
// content. Unknown codes get the internal sentence.
func (c ErrorCode) Message() string {
	if message, ok := errorMessages[c]; ok {
		return message
	}
	return errorMessages[CodeInternal]
}

// Error is a refusal that maps to a channel error code. Reason is a short
// content-free description for tests and logs; it never holds message text.
type Error struct {
	Code   ErrorCode
	Reason string
}

func (e *Error) Error() string { return string(e.Code) + ": " + e.Reason }

func invalid(reason string) error { return &Error{CodeInvalidMessage, reason} }

// CodeOf returns the code carried by err: "" for nil, internal for errors that
// are not an *Error.
func CodeOf(err error) ErrorCode {
	if err == nil {
		return ""
	}
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return CodeInternal
}

// Base64 is a byte string carried as base64url without padding.
type Base64 []byte

func (b Base64) MarshalJSON() ([]byte, error) {
	return json.Marshal(base64.RawURLEncoding.EncodeToString(b))
}

func (b *Base64) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(s)
	if err != nil {
		return invalid("base64url field malformed")
	}
	*b = decoded
	return nil
}

// Purpose is the hello's purpose.
type Purpose string

const (
	PurposeEnroll  Purpose = "enroll"
	PurposeRefresh Purpose = "refresh"
	PurposeSession Purpose = "session"
)

// Hello is the plaintext of the first client frame.
type Hello struct {
	ReplyKey    Base64  `json:"reply_key"`
	Purpose     Purpose `json:"purpose"`
	AccessToken string  `json:"access_token,omitempty"`
}

// Identity is the body of GET /v1/remote/identity.
type Identity struct {
	SchemaVersion    int    `json:"schema_version"`
	Server           string `json:"server"`
	ProtocolVersions []int  `json:"protocol_versions"`
	Suite            string `json:"suite"`
	ServerKey        Base64 `json:"server_key"`
	Fingerprint      string `json:"fingerprint"`
}

// Suite names the channel's HPKE suite in the identity response.
const Suite = "x25519-hkdfsha256-chacha20poly1305"

// Message is one control message. MessageType is its wire type.
type Message interface{ MessageType() string }

// Operation messages carry the client-chosen op number.
type opMessage interface {
	Message
	OpNumber() int64
}

// MessageTypes lists every control message type in contract order.
var MessageTypes = []string{
	"ready", "enroll", "enrolled", "refresh", "tokens", "dictation_start", "dictation_accepted",
	"window_result", "progress", "dictation_end", "dictation_cancel", "dictation_complete",
	"cancelled", "rewrite", "rewrite_event", "analysis_part", "analysis", "analysis_event_part",
	"analysis_event", "live_window", "live_result", "meeting_job", "meeting_progress", "meeting_result",
	"meeting_cancel", "handoff", "handoff_reply", "error",
}

// Ready carries Capabilities on session channels (Feature 018); a ready
// without them is a Feature 014 server.
type Ready struct {
	Capabilities *Capabilities `json:"capabilities,omitempty"`
}

// Capabilities lists the session ops served and, once a meeting worker is
// ready, its job kinds and models (research R11).
type Capabilities struct {
	Ops         []string          `json:"ops"`
	MeetingJobs []string          `json:"meeting_jobs"`
	Models      *CapabilityModels `json:"models,omitempty"`
}

type CapabilityModels struct {
	Transcription *MeetingModel `json:"transcription,omitempty"`
	Diarization   *MeetingModel `json:"diarization,omitempty"`
	Voice         *MeetingModel `json:"voice,omitempty"`
}

// MeetingModel is a meeting model's engine identity; Dimension is the voice
// embedding length and required for the voice model only.
type MeetingModel struct {
	Engine        string `json:"engine"`
	ModelID       string `json:"model_id"`
	ModelRevision string `json:"model_revision"`
	ManifestHash  string `json:"manifest_hash"`
	Dimension     int    `json:"dimension,omitempty"`
}

type Enroll struct {
	Op         int64  `json:"op"`
	Provider   string `json:"provider"`
	IDToken    string `json:"id_token"`
	DeviceName string `json:"device_name"` // control characters removed by DecodeMessage
	DeviceKey  Base64 `json:"device_key"`
	Signature  Base64 `json:"signature"`
}

type Enrolled struct {
	Op           int64  `json:"op"`
	State        string `json:"state"`
	RefreshToken string `json:"refresh_token,omitempty"`
}

type Refresh struct {
	Op           int64  `json:"op"`
	RefreshToken string `json:"refresh_token"`
	Signature    Base64 `json:"signature"`
}

type Tokens struct {
	Op           int64  `json:"op"`
	AccessToken  string `json:"access_token"`
	ExpiresIn    int    `json:"expires_in"`
	RefreshToken string `json:"refresh_token"`
}

type DictationStart struct {
	Op         int64  `json:"op"`
	Format     string `json:"format"`
	SampleRate int    `json:"sample_rate"`
	Boost      *Boost `json:"boost,omitempty"`
}

type Boost struct {
	Terms    []BoostTerm `json:"terms"`
	Governed []string    `json:"governed"`
}

type BoostTerm struct {
	EntryID   string `json:"entry_id"`
	Canonical string `json:"canonical"`
}

type DictationAccepted struct {
	Op            int64         `json:"op"`
	WindowSamples int           `json:"window_samples"`
	Model         ModelIdentity `json:"model"`
}

// ModelIdentity is the worker's model identity; Booster is empty when the
// server has no term booster.
type ModelIdentity struct {
	Engine        string `json:"engine"`
	ModelID       string `json:"model_id"`
	ModelRevision string `json:"model_revision"`
	ManifestHash  string `json:"manifest_hash"`
	SDK           string `json:"sdk"`
	Booster       string `json:"booster,omitempty"`
	WorkerBuild   string `json:"worker_build"`
}

type WindowResult struct {
	Op            int64       `json:"op"`
	Index         int         `json:"index"`
	SampleStart   int         `json:"sample_start"`
	SampleCount   int         `json:"sample_count"`
	Text          string      `json:"text"`
	Tokens        []Token     `json:"tokens"`
	Evidence      *Evidence   `json:"evidence,omitempty"`
	BoostHints    []BoostHint `json:"boost_hints"`
	RecognitionMS int64       `json:"recognition_ms"`
}

type Token struct {
	Text  string  `json:"text"`
	Start float64 `json:"start"`
	End   float64 `json:"end"`
}

// Evidence is the wire form of the client's RecognitionEvidence.
type Evidence struct {
	Text             string          `json:"text"`
	Samples          int             `json:"samples"`
	PaddedSamples    int             `json:"padded_samples"`
	TimingsAvailable bool            `json:"timings_available"`
	Tokens           []EvidenceToken `json:"tokens"`
}

type EvidenceToken struct {
	Text  string `json:"text"`
	Start Timing `json:"start"`
	End   Timing `json:"end"`
}

// Timing is a finite SDK time in Value, or a non-finite marker in Invalid.
type Timing struct {
	Value   *float64 `json:"value,omitempty" remote:"nullable"`
	Invalid string   `json:"invalid,omitempty"`
}

type BoostHint struct {
	Source    string `json:"source"`
	Canonical string `json:"canonical"`
	EntryID   string `json:"entry_id"`
}

type Progress struct {
	Op    int64  `json:"op"`
	State string `json:"state"`
}

type DictationEnd struct {
	Op           int64 `json:"op"`
	TotalSamples int64 `json:"total_samples"`
}

type DictationCancel struct {
	Op int64 `json:"op"`
}

type DictationComplete struct {
	Op      int64 `json:"op"`
	Windows int   `json:"windows"`
}

type Cancelled struct {
	Op int64 `json:"op"`
}

// Rewrite carries an unchanged rewrite request; the rewrite operation
// validates it with the rewrite protocol's own rules.
type Rewrite struct {
	Op      int64           `json:"op"`
	Request json.RawMessage `json:"request"`
}

type RewriteEvent struct {
	Op    int64           `json:"op"`
	Event json.RawMessage `json:"event"`
}

// AnalysisPart is one fragment of a UTF-8 JSON analysis request.
type AnalysisPart struct {
	Op    int64  `json:"op"`
	Index int    `json:"index"`
	Data  string `json:"data"`
}

// Analysis closes an analysis request: the fragment count, the assembled
// size and its lowercase hex SHA-256.
type Analysis struct {
	Op     int64  `json:"op"`
	Parts  int    `json:"parts"`
	Bytes  int    `json:"bytes"`
	SHA256 string `json:"sha256"`
}

// AnalysisEventPart is one fragment of an analysis event line.
type AnalysisEventPart struct {
	Op    int64  `json:"op"`
	Index int    `json:"index"`
	Data  string `json:"data"`
}

// AnalysisEvent carries one event inline in Event, or closes its fragments
// with Parts and SHA256.
type AnalysisEvent struct {
	Op     int64           `json:"op"`
	Event  json.RawMessage `json:"event,omitempty"`
	Parts  int             `json:"parts,omitempty"`
	SHA256 string          `json:"sha256,omitempty"`
}

type LiveWindow struct {
	Op          int64  `json:"op"`
	SampleCount int    `json:"sample_count"`
	Format      string `json:"format"`
	Language    string `json:"language,omitempty"`
}

type LiveResult struct {
	Op            int64            `json:"op"`
	Window        LiveWindowResult `json:"window"`
	RecognitionMS int64            `json:"recognition_ms"`
}

// LiveWindowResult is window_result's window object: text, tokens, evidence.
type LiveWindowResult struct {
	Text     string    `json:"text"`
	Tokens   []Token   `json:"tokens"`
	Evidence *Evidence `json:"evidence,omitempty"`
}

// MeetingJob is one meeting model call. Language, VocabularyTerms and
// Pipeline are for transcribe only, NumSpeakers for diarize only.
type MeetingJob struct {
	Op              int64    `json:"op"`
	Kind            string   `json:"kind"`
	SampleCount     int      `json:"sample_count"`
	Format          string   `json:"format"`
	Language        string   `json:"language,omitempty"`
	VocabularyTerms []string `json:"vocabulary_terms,omitempty"`
	Pipeline        string   `json:"pipeline,omitempty"`
	NumSpeakers     *int     `json:"num_speakers,omitempty"`
}

type MeetingProgress struct {
	Op       int64  `json:"op"`
	State    string `json:"state"`
	Position *int   `json:"position,omitempty"`
}

// MeetingResult carries the result object of its kind: TranscribeResult,
// DiarizeResult or EmbedResult.
type MeetingResult struct {
	Op           int64           `json:"op"`
	Kind         string          `json:"kind"`
	Result       json.RawMessage `json:"result"`
	ProcessingMS int64           `json:"processing_ms"`
	Model        MeetingModel    `json:"model"`
}

// TranscribeResult is the wire form of a final-transcription window.
type TranscribeResult struct {
	Text             string  `json:"text"`
	Tokens           []Token `json:"tokens"`
	TimingsAvailable bool    `json:"timings_available"`
	Language         string  `json:"language,omitempty"`
	RetryDepth       int     `json:"retry_depth"`
	Pipeline         string  `json:"pipeline,omitempty"`
}

// DiarizeResult is the wire form of DiarizationWindowResult.
type DiarizeResult struct {
	Turns     []DiarizationTurn `json:"turns"`
	Centroids []Centroid        `json:"centroids"`
}

type DiarizationTurn struct {
	Cluster int      `json:"cluster"`
	Start   float64  `json:"start"`
	End     float64  `json:"end"`
	Quality *float64 `json:"quality,omitempty"`
}

type Centroid struct {
	Cluster int       `json:"cluster"`
	Vector  []float64 `json:"vector"`
}

// EmbedResult is the wire form of VoiceEmbedding.
type EmbedResult struct {
	Vector        []float64 `json:"vector"`
	SpeechSeconds float64   `json:"speech_seconds"`
}

type MeetingCancel struct {
	Op int64 `json:"op"`
}

// Handoff is one meeting handoff request: put a chunk of a file, start
// processing, list, get a chunk of the processed bundle, or delete. Meeting is
// absent for list only; Name and Offset belong to put (Offset also to get);
// Data and SHA256 to put only.
type Handoff struct {
	Op      int64  `json:"op"`
	Action  string `json:"action"`
	Meeting string `json:"meeting,omitempty"`
	Name    string `json:"name,omitempty"`
	Offset  *int64 `json:"offset,omitempty"`
	Data    Base64 `json:"data,omitempty"`
	SHA256  string `json:"sha256,omitempty"`
}

// HandoffReply answers one handoff. State is absent exactly when Meetings
// (the list reply) is present.
type HandoffReply struct {
	Op       int64             `json:"op"`
	State    string            `json:"state,omitempty"`
	Meeting  string            `json:"meeting,omitempty"`
	Name     string            `json:"name,omitempty"`
	Offset   *int64            `json:"offset,omitempty"`
	Data     Base64            `json:"data,omitempty"`
	Size     *int64            `json:"size,omitempty"`
	SHA256   string            `json:"sha256,omitempty"`
	Detail   string            `json:"detail,omitempty"`
	Meetings *[]HandoffMeeting `json:"meetings,omitempty"`
}

type HandoffMeeting struct {
	Meeting  string `json:"meeting"`
	State    string `json:"state"`
	Detail   string `json:"detail,omitempty"`
	Progress *int   `json:"progress,omitempty"` // processing only, 0-100
}

// ErrorMessage is the error control message. Op is 0 (absent) for hello errors.
type ErrorMessage struct {
	Op      int64     `json:"op,omitempty"`
	Code    ErrorCode `json:"code"`
	Message string    `json:"message"`
}

// NewError builds the error message for code with its fixed sentence.
func NewError(op int64, code ErrorCode) ErrorMessage {
	return ErrorMessage{Op: op, Code: code, Message: code.Message()}
}

func (Ready) MessageType() string             { return "ready" }
func (Enroll) MessageType() string            { return "enroll" }
func (Enrolled) MessageType() string          { return "enrolled" }
func (Refresh) MessageType() string           { return "refresh" }
func (Tokens) MessageType() string            { return "tokens" }
func (DictationStart) MessageType() string    { return "dictation_start" }
func (DictationAccepted) MessageType() string { return "dictation_accepted" }
func (WindowResult) MessageType() string      { return "window_result" }
func (Progress) MessageType() string          { return "progress" }
func (DictationEnd) MessageType() string      { return "dictation_end" }
func (DictationCancel) MessageType() string   { return "dictation_cancel" }
func (DictationComplete) MessageType() string { return "dictation_complete" }
func (Cancelled) MessageType() string         { return "cancelled" }
func (Rewrite) MessageType() string           { return "rewrite" }
func (RewriteEvent) MessageType() string      { return "rewrite_event" }
func (AnalysisPart) MessageType() string      { return "analysis_part" }
func (Analysis) MessageType() string          { return "analysis" }
func (AnalysisEventPart) MessageType() string { return "analysis_event_part" }
func (AnalysisEvent) MessageType() string     { return "analysis_event" }
func (LiveWindow) MessageType() string        { return "live_window" }
func (LiveResult) MessageType() string        { return "live_result" }
func (MeetingJob) MessageType() string        { return "meeting_job" }
func (MeetingProgress) MessageType() string   { return "meeting_progress" }
func (MeetingResult) MessageType() string     { return "meeting_result" }
func (MeetingCancel) MessageType() string     { return "meeting_cancel" }
func (Handoff) MessageType() string           { return "handoff" }
func (HandoffReply) MessageType() string      { return "handoff_reply" }
func (ErrorMessage) MessageType() string      { return "error" }

func (m Enroll) OpNumber() int64            { return m.Op }
func (m Enrolled) OpNumber() int64          { return m.Op }
func (m Refresh) OpNumber() int64           { return m.Op }
func (m Tokens) OpNumber() int64            { return m.Op }
func (m DictationStart) OpNumber() int64    { return m.Op }
func (m DictationAccepted) OpNumber() int64 { return m.Op }
func (m WindowResult) OpNumber() int64      { return m.Op }
func (m Progress) OpNumber() int64          { return m.Op }
func (m DictationEnd) OpNumber() int64      { return m.Op }
func (m DictationCancel) OpNumber() int64   { return m.Op }
func (m DictationComplete) OpNumber() int64 { return m.Op }
func (m Cancelled) OpNumber() int64         { return m.Op }
func (m Rewrite) OpNumber() int64           { return m.Op }
func (m RewriteEvent) OpNumber() int64      { return m.Op }
func (m AnalysisPart) OpNumber() int64      { return m.Op }
func (m Analysis) OpNumber() int64          { return m.Op }
func (m AnalysisEventPart) OpNumber() int64 { return m.Op }
func (m AnalysisEvent) OpNumber() int64     { return m.Op }
func (m LiveWindow) OpNumber() int64        { return m.Op }
func (m LiveResult) OpNumber() int64        { return m.Op }
func (m MeetingJob) OpNumber() int64        { return m.Op }
func (m MeetingProgress) OpNumber() int64   { return m.Op }
func (m MeetingResult) OpNumber() int64     { return m.Op }
func (m MeetingCancel) OpNumber() int64     { return m.Op }
func (m Handoff) OpNumber() int64           { return m.Op }
func (m HandoffReply) OpNumber() int64      { return m.Op }
func (m ErrorMessage) OpNumber() int64      { return m.Op }

// decoders maps a wire type to a function decoding the strict object (without
// schema_version and type) and validating it.
var decoders = map[string]func([]byte) (Message, error){
	"ready":               decodeAs[Ready],
	"enroll":              decodeAs[Enroll],
	"enrolled":            decodeAs[Enrolled],
	"refresh":             decodeAs[Refresh],
	"tokens":              decodeAs[Tokens],
	"dictation_start":     decodeAs[DictationStart],
	"dictation_accepted":  decodeAs[DictationAccepted],
	"window_result":       decodeAs[WindowResult],
	"progress":            decodeAs[Progress],
	"dictation_end":       decodeAs[DictationEnd],
	"dictation_cancel":    decodeAs[DictationCancel],
	"dictation_complete":  decodeAs[DictationComplete],
	"cancelled":           decodeAs[Cancelled],
	"rewrite":             decodeAs[Rewrite],
	"rewrite_event":       decodeAs[RewriteEvent],
	"analysis_part":       decodeAs[AnalysisPart],
	"analysis":            decodeAs[Analysis],
	"analysis_event_part": decodeAs[AnalysisEventPart],
	"analysis_event":      decodeAs[AnalysisEvent],
	"live_window":         decodeAs[LiveWindow],
	"live_result":         decodeAs[LiveResult],
	"meeting_job":         decodeAs[MeetingJob],
	"meeting_progress":    decodeAs[MeetingProgress],
	"meeting_result":      decodeAs[MeetingResult],
	"meeting_cancel":      decodeAs[MeetingCancel],
	"handoff":             decodeAs[Handoff],
	"handoff_reply":       decodeAs[HandoffReply],
	"error":               decodeAs[ErrorMessage],
}

type validator interface{ validate() (Message, error) }

func decodeAs[T validator](body []byte) (Message, error) {
	var value T
	if err := strictDecode(body, &value); err != nil {
		return nil, err
	}
	return value.validate()
}

// DecodeMessage parses and validates one control message payload: over
// MaxControlBytes is limit_exceeded, a schema_version other than 1 is
// unsupported_version, and anything else that breaks the schema is
// invalid_message.
func DecodeMessage(data []byte) (Message, error) {
	raw, err := envelope(data)
	if err != nil {
		return nil, err
	}
	var messageType string
	if _, ok := raw["type"]; !ok || json.Unmarshal(raw["type"], &messageType) != nil {
		return nil, invalid("type not a string")
	}
	decode, ok := decoders[messageType]
	if !ok {
		return nil, invalid("unknown type")
	}
	if value, ok := raw["op"]; ok {
		if err := checkOp(value); err != nil {
			return nil, err
		}
	}
	delete(raw, "schema_version")
	delete(raw, "type")
	body, err := json.Marshal(raw)
	if err != nil {
		return nil, invalid("re-encode failed")
	}
	return decode(body)
}

// envelope applies the checks every JSON payload shares and returns the
// top-level object with schema_version verified.
func envelope(data []byte) (map[string]json.RawMessage, error) {
	if len(data) > MaxControlBytes {
		return nil, &Error{CodeLimitExceeded, "control message over 65,536 bytes"}
	}
	if !utf8.Valid(data) {
		return nil, invalid("not UTF-8")
	}
	var raw map[string]json.RawMessage
	decoder := json.NewDecoder(bytes.NewReader(data))
	if err := decoder.Decode(&raw); err != nil || raw == nil {
		return nil, invalid("not a JSON object")
	}
	if decoder.More() {
		return nil, invalid("trailing data")
	}
	version, ok := raw["schema_version"]
	if !ok {
		return nil, invalid("missing schema_version")
	}
	var v int64
	if trimmed := bytes.TrimSpace(version); len(trimmed) == 0 || trimmed[0] == '"' || json.Unmarshal(trimmed, &v) != nil {
		return nil, invalid("schema_version not an integer")
	}
	if v != SchemaVersion {
		return raw, &Error{CodeUnsupportedVersion, "schema_version unsupported"}
	}
	return raw, nil
}

func checkOp(value json.RawMessage) error {
	var op int64
	if json.Unmarshal(value, &op) != nil || op < 1 || op > MaxOp {
		return invalid("op out of range")
	}
	return nil
}

// strictDecode decodes body into target refusing unknown fields, requiring
// every field whose JSON tag lacks omitempty, and refusing null except for
// fields tagged remote:"nullable".
func strictDecode(body []byte, target any) error {
	if err := checkShape(body, reflect.TypeOf(target).Elem()); err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		if code := CodeOf(err); code != CodeInternal {
			return err
		}
		return invalid("field has the wrong type or is unknown")
	}
	return nil
}

var rawMessageType = reflect.TypeOf(json.RawMessage{})
var base64Type = reflect.TypeOf(Base64{})

func checkShape(data []byte, t reflect.Type) error {
	switch {
	case t == rawMessageType || t == base64Type:
		return nil
	case t.Kind() == reflect.Pointer:
		return checkShape(data, t.Elem())
	case t.Kind() == reflect.Slice:
		var items []json.RawMessage
		if json.Unmarshal(data, &items) != nil {
			return invalid("expected an array")
		}
		for _, item := range items {
			if err := checkShape(item, t.Elem()); err != nil {
				return err
			}
		}
	case t.Kind() == reflect.Struct:
		var object map[string]json.RawMessage
		if json.Unmarshal(data, &object) != nil || object == nil {
			return invalid("expected an object")
		}
		for i := range t.NumField() {
			field := t.Field(i)
			name, options, _ := strings.Cut(field.Tag.Get("json"), ",")
			value, present := object[name]
			if !present {
				if !strings.Contains(options, "omitempty") {
					return invalid("missing field " + name)
				}
				continue
			}
			if string(bytes.TrimSpace(value)) == "null" {
				if field.Tag.Get("remote") != "nullable" {
					return invalid("null field " + name)
				}
				continue
			}
			if err := checkShape(value, field.Type); err != nil {
				return err
			}
		}
	}
	return nil
}

// EncodeMessage writes m with schema_version and type first. It refuses a
// message DecodeMessage would refuse, so the server never emits one.
func EncodeMessage(m Message) ([]byte, error) {
	body, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	prefix := `{"schema_version":1,"type":` + quote(m.MessageType())
	var out []byte
	if string(body) == "{}" {
		out = []byte(prefix + "}")
	} else {
		out = append([]byte(prefix+","), body[1:]...)
	}
	if _, err := DecodeMessage(out); err != nil {
		return nil, err
	}
	return out, nil
}

func quote(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// DecodeHello parses the hello plaintext. On error it still returns the
// reply key when that field alone is valid, so the server can seal the error.
func DecodeHello(data []byte) (Hello, error) {
	raw, err := envelope(data)
	var replyKey Base64
	if value, ok := raw["reply_key"]; ok && json.Unmarshal(value, &replyKey) == nil && len(replyKey) == KeyBytes {
		replyKey = bytes.Clone(replyKey)
	} else {
		replyKey = nil
	}
	hello, err := decodeHello(raw, err)
	if err != nil {
		return Hello{ReplyKey: replyKey}, err
	}
	return hello, nil
}

func decodeHello(raw map[string]json.RawMessage, err error) (Hello, error) {
	var hello Hello
	if err != nil {
		return hello, err
	}
	var messageType string
	if _, ok := raw["type"]; !ok || json.Unmarshal(raw["type"], &messageType) != nil || messageType != "hello" {
		return hello, invalid("not a hello")
	}
	delete(raw, "schema_version")
	delete(raw, "type")
	body, _ := json.Marshal(raw)
	if err := strictDecode(body, &hello); err != nil {
		return hello, err
	}
	if len(hello.ReplyKey) != KeyBytes {
		return hello, invalid("reply_key not 32 bytes")
	}
	switch hello.Purpose {
	case PurposeSession:
		// A missing token breaks the schema; a present but malformed one is
		// a credential the server does not accept (contract: unauthorized).
		if hello.AccessToken == "" {
			return hello, invalid("access_token missing")
		}
		if !validToken(hello.AccessToken, "lfa_") {
			return hello, &Error{CodeUnauthorized, "access_token malformed"}
		}
	case PurposeEnroll, PurposeRefresh:
		if _, present := raw["access_token"]; present {
			return hello, invalid("access_token only for session")
		}
	default:
		return hello, invalid("unknown purpose")
	}
	return hello, nil
}

// DecodeIdentity parses an identity response; flowd only writes these, so it
// exists for tests and tools.
func DecodeIdentity(data []byte) (Identity, error) {
	var identity Identity
	raw, err := envelope(data)
	if err != nil {
		return identity, err
	}
	body, _ := json.Marshal(raw)
	if err := strictDecode(body, &identity); err != nil {
		return Identity{}, err
	}
	if identity.Suite != Suite || len(identity.ServerKey) != KeyBytes || !validFingerprint(identity.Fingerprint) ||
		!strings.HasPrefix(identity.Server, "flowd/") || len(identity.ProtocolVersions) == 0 {
		return Identity{}, invalid("identity field invalid")
	}
	return identity, nil
}

func validFingerprint(s string) bool {
	if len(s) != 39 {
		return false
	}
	for i, r := range s {
		if i%5 == 4 {
			if r != '-' {
				return false
			}
		} else if !strings.ContainsRune("0123456789abcdef", r) {
			return false
		}
	}
	return true
}

// validToken accepts prefix plus 32 bytes in base64url without padding.
func validToken(token, prefix string) bool {
	rest, ok := strings.CutPrefix(token, prefix)
	if !ok || len(rest) != 43 {
		return false
	}
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(rest)
	return err == nil && len(decoded) == 32
}

// SanitizeDeviceName removes control characters (C0, DEL, C1 and the Unicode
// bidirectional controls that could reorder admin output) and surrounding
// spaces. The result must be 1…64 bytes to be accepted.
func SanitizeDeviceName(name string) string {
	var b strings.Builder
	for _, r := range name {
		if unicode.IsControl(r) || (r >= 0x202a && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069) || r == utf8.RuneError {
			continue
		}
		b.WriteRune(r)
	}
	return strings.TrimSpace(b.String())
}

func textWithin(s string, min, max int) bool { return len(s) >= min && len(s) <= max }

func (m Ready) validate() (Message, error) {
	c := m.Capabilities
	if c == nil {
		return m, nil
	}
	if len(c.Ops) > maxCapabilityOps || !distinct(c.Ops, validOpName) {
		return nil, invalid("capabilities ops")
	}
	if len(c.MeetingJobs) > len(MeetingSamples) || !distinct(c.MeetingJobs, func(kind string) bool { _, ok := MeetingSamples[kind]; return ok }) {
		return nil, invalid("capabilities meeting_jobs")
	}
	if models := c.Models; models != nil {
		for _, model := range []*MeetingModel{models.Transcription, models.Diarization, models.Voice} {
			if model != nil && !model.valid() {
				return nil, invalid("capabilities model identity")
			}
		}
		if models.Voice != nil && models.Voice.Dimension == 0 {
			return nil, invalid("voice model without dimension")
		}
	}
	return m, nil
}

// distinct reports whether every item is valid and appears once.
func distinct(items []string, valid func(string) bool) bool {
	seen := map[string]bool{}
	for _, item := range items {
		if !valid(item) || seen[item] {
			return false
		}
		seen[item] = true
	}
	return true
}

func validOpName(s string) bool {
	return textWithin(s, 1, 32) && strings.Trim(s, "abcdefghijklmnopqrstuvwxyz_") == ""
}

func (m MeetingModel) valid() bool {
	for _, field := range []string{m.Engine, m.ModelID, m.ModelRevision, m.ManifestHash} {
		if !textWithin(field, 1, maxIdentityBytes) {
			return false
		}
	}
	return m.Dimension >= 0 && m.Dimension <= maxVectorLength
}

func (m Enroll) validate() (Message, error) {
	if m.Provider != "apple" && m.Provider != "google" {
		return nil, invalid("provider unknown")
	}
	if !textWithin(m.IDToken, 1, maxIDTokenBytes) || !validJWTShape(m.IDToken) {
		return nil, invalid("id_token malformed")
	}
	m.DeviceName = SanitizeDeviceName(m.DeviceName)
	if !textWithin(m.DeviceName, 1, MaxDeviceNameBytes) {
		return nil, invalid("device_name length")
	}
	if len(m.DeviceKey) != DeviceKeyBytes || m.DeviceKey[0] != 0x04 {
		return nil, invalid("device_key not X9.63 uncompressed")
	}
	if _, err := ecdh.P256().NewPublicKey(m.DeviceKey); err != nil {
		return nil, invalid("device_key not a P-256 point")
	}
	if len(m.Signature) < 8 || len(m.Signature) > 72 {
		return nil, invalid("signature length")
	}
	return m, nil
}

func validJWTShape(token string) bool {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return false
	}
	for _, part := range parts {
		if part == "" || strings.Trim(part, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_") != "" {
			return false
		}
	}
	return true
}

func (m Enrolled) validate() (Message, error) {
	switch m.State {
	case "rejected":
		if m.RefreshToken != "" {
			return nil, invalid("rejected carries no refresh token")
		}
	case "pending", "approved":
		if !validToken(m.RefreshToken, "lfr_") {
			return nil, invalid("refresh_token malformed")
		}
	default:
		return nil, invalid("state unknown")
	}
	return m, nil
}

func (m Refresh) validate() (Message, error) {
	if !validToken(m.RefreshToken, "lfr_") {
		return nil, invalid("refresh_token malformed")
	}
	if len(m.Signature) < 8 || len(m.Signature) > 72 {
		return nil, invalid("signature length")
	}
	return m, nil
}

func (m Tokens) validate() (Message, error) {
	if !validToken(m.AccessToken, "lfa_") || !validToken(m.RefreshToken, "lfr_") {
		return nil, invalid("token malformed")
	}
	if m.ExpiresIn < 1 || m.ExpiresIn > maxExpiresIn {
		return nil, invalid("expires_in out of range")
	}
	return m, nil
}

func (m DictationStart) validate() (Message, error) {
	if m.Format != AudioFormat || m.SampleRate != SampleRate {
		return nil, invalid("audio format")
	}
	if m.Boost != nil {
		if len(m.Boost.Terms) > MaxBoostTerms || len(m.Boost.Governed) > MaxGovernedSpellings {
			return nil, invalid("boost over limits")
		}
		for _, term := range m.Boost.Terms {
			if !textWithin(term.EntryID, 1, MaxTermBytes) || !textWithin(term.Canonical, 1, MaxTermBytes) {
				return nil, invalid("boost term length")
			}
		}
		for _, spelling := range m.Boost.Governed {
			if !textWithin(spelling, 1, MaxTermBytes) {
				return nil, invalid("governed spelling length")
			}
		}
	}
	return m, nil
}

func (m DictationAccepted) validate() (Message, error) {
	if m.WindowSamples != WindowSamples {
		return nil, invalid("window_samples")
	}
	model := m.Model
	for _, field := range []string{model.Engine, model.ModelID, model.ModelRevision, model.ManifestHash, model.SDK, model.WorkerBuild} {
		if !textWithin(field, 1, maxIdentityBytes) {
			return nil, invalid("model identity field")
		}
	}
	if len(model.Booster) > maxIdentityBytes {
		return nil, invalid("booster length")
	}
	return m, nil
}

func (m WindowResult) validate() (Message, error) {
	if m.Index < 0 || m.Index >= MaxWindows || m.SampleStart < 0 || m.SampleStart > 2880000 ||
		m.SampleCount < 1 || m.SampleCount > WindowSamples || m.RecognitionMS < 0 || m.RecognitionMS > maxRecognitionMS {
		return nil, invalid("window bounds")
	}
	if len(m.BoostHints) > MaxBoostTerms {
		return nil, invalid("window content bounds")
	}
	if err := validWindow(m.Text, m.Tokens, m.Evidence); err != nil {
		return nil, err
	}
	for _, hint := range m.BoostHints {
		if !textWithin(hint.Source, 1, 512) || !textWithin(hint.Canonical, 1, MaxTermBytes) || !textWithin(hint.EntryID, 1, MaxTermBytes) {
			return nil, invalid("boost hint length")
		}
	}
	return m, nil
}

// validWindow checks the text, tokens and evidence shared by window_result,
// live_result and the transcribe result.
func validWindow(text string, tokens []Token, e *Evidence) error {
	if len(text) > MaxControlBytes || len(tokens) > maxTokens {
		return invalid("window content bounds")
	}
	for _, token := range tokens {
		if !finiteNonNegative(token.Start) || !finiteNonNegative(token.End) {
			return invalid("token timing")
		}
	}
	if e != nil {
		if e.Samples < 0 || e.PaddedSamples < 0 || len(e.Tokens) > maxTokens {
			return invalid("evidence bounds")
		}
		for _, token := range e.Tokens {
			for _, timing := range []Timing{token.Start, token.End} {
				switch timing.Invalid {
				case "", "nan", "positive_infinity", "negative_infinity":
				default:
					return invalid("evidence timing marker")
				}
			}
		}
	}
	return nil
}

func finiteNonNegative(v float64) bool { return v >= 0 && !math.IsInf(v, 0) && !math.IsNaN(v) }

func (m Progress) validate() (Message, error) {
	if m.State != "queued" && m.State != "recognizing" {
		return nil, invalid("progress state")
	}
	return m, nil
}

func (m DictationEnd) validate() (Message, error) {
	if m.TotalSamples < 0 || m.TotalSamples > MaxSessionSamples {
		return nil, invalid("total_samples out of range")
	}
	return m, nil
}

func (m DictationCancel) validate() (Message, error) { return m, nil }

func (m DictationComplete) validate() (Message, error) {
	if m.Windows < 0 || m.Windows > MaxWindows {
		return nil, invalid("windows out of range")
	}
	return m, nil
}

func (m Cancelled) validate() (Message, error) { return m, nil }

func (m Rewrite) validate() (Message, error) {
	if !isObject(m.Request) {
		return nil, invalid("request not an object")
	}
	return m, nil
}

func (m RewriteEvent) validate() (Message, error) {
	if !isObject(m.Event) {
		return nil, invalid("event not an object")
	}
	return m, nil
}

func isObject(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	return len(trimmed) > 0 && trimmed[0] == '{'
}

// validPart checks an analysis_part or analysis_event_part fragment.
func validPart(index int, data string) error {
	switch {
	case index < 0 || index >= MaxAnalysisParts || data == "":
		return invalid("analysis fragment")
	case len(data) > MaxAnalysisPartBytes:
		return &Error{CodeLimitExceeded, "analysis fragment over 49,152 bytes"}
	}
	return nil
}

func validSHA256(s string) bool {
	return len(s) == 64 && strings.Trim(s, "0123456789abcdef") == ""
}

func (m AnalysisPart) validate() (Message, error) { return m, validPart(m.Index, m.Data) }

func (m Analysis) validate() (Message, error) {
	switch {
	case m.Parts < 1 || m.Parts > MaxAnalysisParts || m.Bytes < 1 || !validSHA256(m.SHA256):
		return nil, invalid("analysis close")
	case m.Bytes > MaxAnalysisBytes:
		return nil, &Error{CodeLimitExceeded, "analysis request over 262,144 bytes"}
	}
	return m, nil
}

func (m AnalysisEventPart) validate() (Message, error) { return m, validPart(m.Index, m.Data) }

func (m AnalysisEvent) validate() (Message, error) {
	if len(m.Event) > 0 {
		if m.Parts != 0 || m.SHA256 != "" || !isObject(m.Event) {
			return nil, invalid("analysis event inline")
		}
		return m, nil
	}
	if m.Parts < 1 || m.Parts > MaxAnalysisParts || !validSHA256(m.SHA256) {
		return nil, invalid("analysis event close")
	}
	return m, nil
}

// validLanguage accepts a two- or three-letter lowercase code, and "auto"
// where the client may leave the choice to the model.
func validLanguage(s string, auto bool) bool {
	return (auto && s == "auto") || (textWithin(s, 2, 3) && strings.Trim(s, "abcdefghijklmnopqrstuvwxyz") == "")
}

func (m LiveWindow) validate() (Message, error) {
	if m.SampleCount < 1 || m.SampleCount > MaxLiveSamples || m.Format != SampleFormat {
		return nil, invalid("live window samples")
	}
	if m.Language != "" && !validLanguage(m.Language, true) {
		return nil, invalid("live window language")
	}
	return m, nil
}

func (m LiveResult) validate() (Message, error) {
	if m.RecognitionMS < 0 || m.RecognitionMS > maxRecognitionMS {
		return nil, invalid("live result bounds")
	}
	return m, validWindow(m.Window.Text, m.Window.Tokens, m.Window.Evidence)
}

func (m MeetingJob) validate() (Message, error) {
	bounds, ok := MeetingSamples[m.Kind]
	if !ok || m.SampleCount < bounds[0] || m.SampleCount > bounds[1] || m.Format != SampleFormat {
		return nil, invalid("meeting job samples")
	}
	transcribeOptions := m.Language != "" || m.VocabularyTerms != nil || m.Pipeline != ""
	if (m.Kind != "transcribe" && transcribeOptions) || (m.Kind != "diarize" && m.NumSpeakers != nil) {
		return nil, invalid("meeting job option for another kind")
	}
	if (m.Language != "" && !validLanguage(m.Language, true)) || len(m.Pipeline) > maxIdentityBytes ||
		len(m.VocabularyTerms) > maxVocabularyTerms {
		return nil, invalid("meeting job options")
	}
	for _, term := range m.VocabularyTerms {
		if !textWithin(term, 1, MaxTermBytes) {
			return nil, invalid("vocabulary term length")
		}
	}
	if m.NumSpeakers != nil && (*m.NumSpeakers < 1 || *m.NumSpeakers > maxSpeakers) {
		return nil, invalid("num_speakers out of range")
	}
	return m, nil
}

func (m MeetingProgress) validate() (Message, error) {
	if (m.State != "queued" && m.State != "running") || (m.Position != nil && (*m.Position < 0 || *m.Position > maxQueuePosition)) {
		return nil, invalid("meeting progress")
	}
	return m, nil
}

func (m MeetingResult) validate() (Message, error) {
	if m.ProcessingMS < 0 || m.ProcessingMS > maxRecognitionMS || !m.Model.valid() {
		return nil, invalid("meeting result bounds")
	}
	var err error
	switch m.Kind {
	case "transcribe":
		var r TranscribeResult
		if err = strictDecode(m.Result, &r); err == nil {
			err = r.validate()
		}
	case "diarize":
		var r DiarizeResult
		if err = strictDecode(m.Result, &r); err == nil {
			err = r.validate()
		}
	case "embed":
		var r EmbedResult
		if err = strictDecode(m.Result, &r); err == nil {
			err = validVector(r.Vector)
		}
		if err == nil && !finiteNonNegative(r.SpeechSeconds) {
			err = invalid("speech_seconds")
		}
	default:
		err = invalid("meeting result kind")
	}
	if err != nil {
		return nil, err
	}
	return m, nil
}

func (r TranscribeResult) validate() error {
	if r.RetryDepth < 0 || r.RetryDepth > maxRetryDepth || (r.Language != "" && !validLanguage(r.Language, false)) ||
		len(r.Pipeline) > maxIdentityBytes {
		return invalid("transcribe result fields")
	}
	return validWindow(r.Text, r.Tokens, nil)
}

func (r DiarizeResult) validate() error {
	if len(r.Turns) > maxTurns || len(r.Centroids) > maxClusters {
		return invalid("diarize result bounds")
	}
	for _, turn := range r.Turns {
		if turn.Cluster < 0 || turn.Cluster >= maxClusters || !finiteNonNegative(turn.Start) || !(turn.Start < turn.End) {
			return invalid("diarization turn")
		}
	}
	for _, centroid := range r.Centroids {
		if centroid.Cluster < 0 || centroid.Cluster >= maxClusters {
			return invalid("centroid cluster")
		}
		if err := validVector(centroid.Vector); err != nil {
			return err
		}
	}
	return nil
}

// validVector bounds an embedding or centroid; JSON numbers are always finite.
func validVector(v []float64) error {
	if len(v) < 1 || len(v) > maxVectorLength {
		return invalid("vector length")
	}
	return nil
}

func (m MeetingCancel) validate() (Message, error) { return m, nil }

var handoffName = regexp.MustCompile(`^(bundle\.sqlite|(mic|system)-[0-9]{4}\.aac)$`)

// validMeetingID accepts an uppercase canonical UUID.
func validMeetingID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, r := range s {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if r != '-' {
				return false
			}
		} else if !strings.ContainsRune("0123456789ABCDEF", r) {
			return false
		}
	}
	return true
}

func validHandoffState(s string) bool {
	switch s {
	case "receiving", "queued", "processing", "done", "failed", "missing":
		return true
	}
	return false
}

// validHandoffDetail allows a short lowercase code, on failed only.
func validHandoffDetail(state, detail string) bool {
	return detail == "" || (state == "failed" && textWithin(detail, 1, maxHandoffDetail) &&
		strings.Trim(detail, "abcdefghijklmnopqrstuvwxyz0123456789_") == "")
}

func (m Handoff) validate() (Message, error) {
	put, get := m.Action == "put", m.Action == "get"
	switch m.Action {
	case "put", "start", "list", "get", "delete":
	default:
		return nil, invalid("handoff action")
	}
	switch {
	case (m.Action == "list") != (m.Meeting == "") || (m.Meeting != "" && !validMeetingID(m.Meeting)):
		return nil, invalid("handoff meeting")
	case put != (m.Name != "") || (put && !handoffName.MatchString(m.Name)):
		return nil, invalid("handoff name")
	case (put || get) != (m.Offset != nil) || (m.Offset != nil && (*m.Offset < 0 || *m.Offset > MaxHandoffFileBytes)):
		return nil, invalid("handoff offset")
	case m.Data != nil && (!put || len(m.Data) == 0), m.SHA256 != "" && (!put || !validSHA256(m.SHA256)):
		return nil, invalid("handoff data")
	case len(m.Data) > MaxHandoffChunkBytes:
		return nil, &Error{CodeLimitExceeded, "handoff chunk over 48,000 bytes"}
	}
	return m, nil
}

func (m HandoffReply) validate() (Message, error) {
	if m.Meetings != nil {
		if m.State != "" || m.Meeting != "" || m.Name != "" || m.Offset != nil || m.Data != nil || m.Size != nil ||
			m.SHA256 != "" || m.Detail != "" || len(*m.Meetings) > maxHandoffList {
			return nil, invalid("handoff list reply")
		}
		for _, entry := range *m.Meetings {
			if !validMeetingID(entry.Meeting) || !validHandoffState(entry.State) || !validHandoffDetail(entry.State, entry.Detail) {
				return nil, invalid("handoff list entry")
			}
		}
		return m, nil
	}
	if !validHandoffState(m.State) || (m.Meeting != "" && !validMeetingID(m.Meeting)) || !validHandoffDetail(m.State, m.Detail) ||
		(m.Name != "" && !handoffName.MatchString(m.Name)) || (m.Offset != nil && *m.Offset < 0) || (m.Size != nil && *m.Size < 0) ||
		(m.SHA256 != "" && !validSHA256(m.SHA256)) || len(m.Data) > MaxHandoffChunkBytes {
		return nil, invalid("handoff reply")
	}
	return m, nil
}

func (m ErrorMessage) validate() (Message, error) {
	if _, ok := errorMessages[m.Code]; !ok {
		return nil, invalid("error code unknown")
	}
	if !textWithin(m.Message, 1, maxErrorMessageBytes) {
		return nil, invalid("error message length")
	}
	return m, nil
}
