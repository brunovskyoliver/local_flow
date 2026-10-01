// Package speech runs the speech worker child processes and schedules jobs on
// them. The worker contracts are
// specs/014-remote-dictation-server/contracts/speech-worker-ipc.md and, for
// the meeting worker, specs/018-one-server/contracts/meeting-worker-ipc.md;
// this package depends only on those messages, never on flowd-speech itself
// (FR-029).
package speech

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"unicode/utf8"
)

// Framing and message bounds.
const (
	ProtocolVersion = 1
	MaxHeaderBytes  = 65536
	// MaxSampleCount is one recognition window (research R11).
	MaxSampleCount = 239360
)

// Message types.
const (
	TypeReady       = "ready"
	TypeUnavailable = "unavailable"
	TypeRecognize   = "recognize"
	TypeShutdown    = "shutdown"
	TypeResult      = "result"
	TypeError       = "error"
	TypeState       = "state"
	// Meeting worker jobs (Feature 018). A result names its job's kind.
	TypeTranscribe = "transcribe"
	TypeDiarize    = "diarize"
	TypeEmbed      = "embed"
)

// MeetingSampleRange is the sample_count range of each meeting job kind.
var MeetingSampleRange = map[string][2]int{
	TypeTranscribe: {1, 1920000},
	TypeDiarize:    {1, 9600000},
	TypeEmbed:      {48000, 320000},
}

// maxPayloadBytes is the largest payload of any frame: a diarization window.
const maxPayloadBytes = 4 * 9600000

// Worker error codes in an error message.
const (
	CodeInvalidAudio     = "invalid_audio"
	CodeModelUnavailable = "model_unavailable"
	CodeFailed           = "failed"
	// CodeRepetition: the meeting worker's transcription kept repeating.
	CodeRepetition = "repetition"
)

// ErrMalformedFrame wraps every framing or schema violation. It is fatal: the
// reader must be closed and the worker restarted.
var ErrMalformedFrame = errors.New("speech: malformed worker frame")

// ErrHeaderTooLarge is returned by the encoder when a header would exceed
// MaxHeaderBytes, for example a recognize with a very large boost list.
// Nothing is written, so the worker is unaffected.
var ErrHeaderTooLarge = errors.New("speech: frame header over limit")

// ModelIdentity is the worker's model identity from ready, reported to clients
// in dictation_accepted. Booster is empty when no keyword spotter is installed.
type ModelIdentity struct {
	Engine        string `json:"engine"`
	ModelID       string `json:"model_id"`
	ModelRevision string `json:"model_revision"`
	ManifestHash  string `json:"manifest_hash"`
	SDK           string `json:"sdk"`
	Booster       string `json:"booster,omitempty"`
	WorkerBuild   string `json:"worker_build"`
}

// MeetingModel is one meeting model's identity from the meeting worker's
// ready. Dimension is the voice embedding length, voice model only.
type MeetingModel struct {
	Engine        string `json:"engine"`
	ModelID       string `json:"model_id"`
	ModelRevision string `json:"model_revision"`
	ManifestHash  string `json:"manifest_hash"`
	Dimension     int    `json:"dimension,omitempty"`
}

func (m *MeetingModel) valid() bool {
	return m != nil && m.Engine != "" && m.ModelID != "" && m.ModelRevision != "" && m.ManifestHash != ""
}

// MeetingModels are the meeting worker's three models; a ready carries all of
// them.
type MeetingModels struct {
	Transcription *MeetingModel `json:"transcription"`
	Diarization   *MeetingModel `json:"diarization"`
	Voice         *MeetingModel `json:"voice"`
}

// For returns the model that serves a job kind.
func (m MeetingModels) For(kind string) MeetingModel {
	switch kind {
	case TypeTranscribe:
		return *m.Transcription
	case TypeDiarize:
		return *m.Diarization
	}
	return *m.Voice
}

// BoostTerm is one Dictionary entry sent with a recognize job.
type BoostTerm struct {
	EntryID   string `json:"entry_id"`
	Canonical string `json:"canonical"`
}

// Boost is a job's term-boosting input. It applies to that job only.
type Boost struct {
	Terms    []BoostTerm `json:"terms"`
	Governed []string    `json:"governed"`
}

// Header is the JSON header of every message; which fields are set depends on
// Type. Window and Result are the worker's objects, passed through unparsed.
// A dictation ready carries Model, a meeting ready Models.
type Header struct {
	Type            string          `json:"type"`
	Protocol        int             `json:"protocol,omitempty"`
	Model           *ModelIdentity  `json:"model,omitempty"`
	Models          *MeetingModels  `json:"models,omitempty"`
	Reason          string          `json:"reason,omitempty"`
	Missing         []string        `json:"missing,omitempty"`
	Job             uint64          `json:"job,omitempty"`
	SampleCount     int             `json:"sample_count,omitempty"`
	Boost           *Boost          `json:"boost,omitempty"`
	Language        string          `json:"language,omitempty"`
	VocabularyTerms []string        `json:"vocabulary_terms,omitempty"`
	Pipeline        string          `json:"pipeline,omitempty"`
	NumSpeakers     *int            `json:"num_speakers,omitempty"`
	Window          json.RawMessage `json:"window,omitempty"`
	RecognitionMS   *int            `json:"recognition_ms,omitempty"`
	Kind            string          `json:"kind,omitempty"`
	Result          json.RawMessage `json:"result,omitempty"`
	ProcessingMS    *int            `json:"processing_ms,omitempty"`
	Code            string          `json:"code,omitempty"`
	State           string          `json:"state,omitempty"`
}

func isObject(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	return len(trimmed) > 0 && trimmed[0] == '{'
}

// Frame is one decoded message.
type Frame struct {
	Header  Header
	Payload []byte
}

func malformed(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrMalformedFrame, fmt.Sprintf(format, args...))
}

// validate checks the per-type required fields; payloadLength is what the
// frame declares (or carries).
func (h Header) validate(payloadLength uint32) error {
	want := uint32(0)
	switch h.Type {
	case TypeReady:
		if h.Protocol != ProtocolVersion {
			return malformed("ready protocol %d", h.Protocol)
		}
		if m := h.Models; m != nil {
			if h.Model != nil || !m.Transcription.valid() || !m.Diarization.valid() || !m.Voice.valid() || m.Voice.Dimension < 1 {
				return malformed("ready without meeting model identities")
			}
			break
		}
		m := h.Model
		if m == nil || m.Engine == "" || m.ModelID == "" || m.ModelRevision == "" || m.ManifestHash == "" || m.SDK == "" || m.WorkerBuild == "" {
			return malformed("ready without model identity")
		}
	case TypeUnavailable:
		if h.Reason == "" {
			return malformed("unavailable without reason")
		}
	case TypeRecognize:
		if h.Job == 0 {
			return malformed("recognize without job")
		}
		if h.SampleCount < 1 || h.SampleCount > MaxSampleCount {
			return malformed("sample_count %d out of range", h.SampleCount)
		}
		want = uint32(h.SampleCount) * 4
	case TypeTranscribe, TypeDiarize, TypeEmbed:
		bounds := MeetingSampleRange[h.Type]
		if h.Job == 0 {
			return malformed("%s without job", h.Type)
		}
		if h.SampleCount < bounds[0] || h.SampleCount > bounds[1] {
			return malformed("sample_count %d out of range", h.SampleCount)
		}
		want = uint32(h.SampleCount) * 4
	case TypeShutdown:
	case TypeResult:
		if h.Kind != "" {
			if _, ok := MeetingSampleRange[h.Kind]; !ok || h.Job == 0 || h.ProcessingMS == nil || *h.ProcessingMS < 0 || !isObject(h.Result) {
				return malformed("meeting result without job, kind, result or processing_ms")
			}
			break
		}
		if h.Job == 0 || h.RecognitionMS == nil || *h.RecognitionMS < 0 {
			return malformed("result without job or recognition_ms")
		}
		if !isObject(h.Window) {
			return malformed("result window not an object")
		}
	case TypeError:
		if h.Job == 0 {
			return malformed("error without job")
		}
		switch h.Code {
		case CodeInvalidAudio, CodeModelUnavailable, CodeFailed, CodeRepetition:
		default:
			return malformed("unknown error code")
		}
	case TypeState:
		if h.State != "active" && h.State != "releasing" && h.State != "loading" {
			return malformed("unknown state")
		}
	default:
		return malformed("unknown message type")
	}
	if payloadLength != want {
		return malformed("%s payload_length %d, want %d", h.Type, payloadLength, want)
	}
	return nil
}

// EncodeHeader renders a header as compact JSON with object keys sorted by
// byte order at every level and no HTML escaping, the form the shared
// fixtures use.
func EncodeHeader(h Header) ([]byte, error) {
	data, err := json.Marshal(h)
	if err != nil {
		return nil, err
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var generic any
	if err := dec.Decode(&generic); err != nil {
		return nil, err
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(generic); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(out.Bytes(), []byte("\n")), nil
}

// EncodeFrame builds one complete frame. It refuses anything ReadFrame would
// reject, so flowd never sends a malformed frame.
func EncodeFrame(h Header, payload []byte) ([]byte, error) {
	prefix, err := encodePrefix(h, len(payload))
	if err != nil {
		return nil, err
	}
	return append(prefix, payload...), nil
}

// encodePrefix builds everything of a frame before its payload, with room
// for the payload when it is small enough to append (a recognize window).
func encodePrefix(h Header, payloadLength int) ([]byte, error) {
	if payloadLength > maxPayloadBytes {
		return nil, fmt.Errorf("speech: payload %d bytes over limit", payloadLength)
	}
	if err := h.validate(uint32(payloadLength)); err != nil {
		return nil, err
	}
	header, err := EncodeHeader(h)
	if err != nil {
		return nil, err
	}
	if len(header) > MaxHeaderBytes {
		return nil, ErrHeaderTooLarge
	}
	capacity := 8 + len(header)
	if payloadLength <= 4*MaxSampleCount {
		capacity += payloadLength
	}
	out := make([]byte, 0, capacity)
	out = binary.BigEndian.AppendUint32(out, uint32(len(header)))
	out = append(out, header...)
	return binary.BigEndian.AppendUint32(out, uint32(payloadLength)), nil
}

// WriteFrame encodes and writes one frame in a single Write.
func WriteFrame(w io.Writer, h Header, payload []byte) error {
	data, err := EncodeFrame(h, payload)
	if err != nil {
		return err
	}
	_, err = w.Write(data)
	return err
}

// ReadFrame reads one frame. It returns io.EOF only at a clean frame boundary;
// every other failure wraps ErrMalformedFrame and is fatal. Lengths are
// checked before anything is allocated for them.
func ReadFrame(r io.Reader) (Frame, error) {
	var f Frame
	var n [4]byte
	if _, err := io.ReadFull(r, n[:]); err != nil {
		if err == io.EOF {
			return f, io.EOF
		}
		return f, malformed("short read in header_length")
	}
	headerLength := binary.BigEndian.Uint32(n[:])
	if headerLength == 0 || headerLength > MaxHeaderBytes {
		return f, malformed("header_length %d", headerLength)
	}
	header := make([]byte, headerLength)
	if _, err := io.ReadFull(r, header); err != nil {
		return f, malformed("short read in header")
	}
	if !utf8.Valid(header) {
		return f, malformed("header not UTF-8")
	}
	trimmed := bytes.TrimSpace(header)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return f, malformed("header not an object")
	}
	dec := json.NewDecoder(bytes.NewReader(header))
	if err := dec.Decode(&f.Header); err != nil {
		return f, malformed("header not valid JSON")
	}
	if dec.More() {
		return f, malformed("trailing data after header")
	}
	if _, err := io.ReadFull(r, n[:]); err != nil {
		return f, malformed("short read in payload_length")
	}
	payloadLength := binary.BigEndian.Uint32(n[:])
	if err := f.Header.validate(payloadLength); err != nil {
		return f, err
	}
	if payloadLength > 0 {
		f.Payload = make([]byte, payloadLength)
		if _, err := io.ReadFull(r, f.Payload); err != nil {
			return f, malformed("short read in payload")
		}
	}
	return f, nil
}

// EncodeSamples renders Float32 samples little-endian.
func EncodeSamples(samples []float32) []byte {
	out := make([]byte, 4*len(samples))
	for i, s := range samples {
		binary.LittleEndian.PutUint32(out[4*i:], math.Float32bits(s))
	}
	return out
}

// s16ChunkSamples is how many samples WriteS16AsF32 converts per write.
const s16ChunkSamples = 16384

// WriteS16AsF32 writes s16le samples to w as f32le (sample / 32768), one
// bounded chunk at a time, so a meeting payload is never held twice: flowd
// keeps the client's s16le samples and streams the worker's f32le payload.
func WriteS16AsF32(w io.Writer, s16 []byte) error {
	if len(s16)%2 != 0 {
		return errors.New("speech: s16le payload not a whole number of samples")
	}
	chunk := make([]byte, 4*min(s16ChunkSamples, len(s16)/2))
	for len(s16) > 0 {
		n := min(s16ChunkSamples, len(s16)/2)
		for i := range n {
			sample := int16(binary.LittleEndian.Uint16(s16[2*i:]))
			binary.LittleEndian.PutUint32(chunk[4*i:], math.Float32bits(float32(sample)/32768))
		}
		if _, err := w.Write(chunk[:4*n]); err != nil {
			return err
		}
		s16 = s16[2*n:]
	}
	return nil
}

// DecodeSamples parses a Float32 little-endian payload.
func DecodeSamples(payload []byte) ([]float32, error) {
	if len(payload)%4 != 0 {
		return nil, errors.New("speech: payload not a whole number of samples")
	}
	out := make([]float32, len(payload)/4)
	for i := range out {
		out[i] = math.Float32frombits(binary.LittleEndian.Uint32(payload[4*i:]))
	}
	return out, nil
}
