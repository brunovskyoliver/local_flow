package speech

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite fixtures/remote/worker-frames from the Go encoder")

const fixtureDir = "../../../fixtures/remote/worker-frames"

// frame builds a frame by hand, independent of the package encoder.
func frame(header string, payload []byte) []byte {
	var b bytes.Buffer
	_ = binary.Write(&b, binary.BigEndian, uint32(len(header)))
	b.WriteString(header)
	_ = binary.Write(&b, binary.BigEndian, uint32(len(payload)))
	b.Write(payload)
	return b.Bytes()
}

func TestShutdownFrameBytes(t *testing.T) {
	got, err := EncodeFrame(Header{Type: TypeShutdown}, nil)
	if err != nil {
		t.Fatal(err)
	}
	want := frame(`{"type":"shutdown"}`, nil)
	if !bytes.Equal(got, want) {
		t.Fatalf("got % x\nwant % x", got, want)
	}
}

func TestHeaderKeysSortedCompact(t *testing.T) {
	h := Header{Type: TypeRecognize, Job: 17, SampleCount: 1, Boost: &Boost{Terms: []BoostTerm{{EntryID: "e", Canonical: "C&D"}}, Governed: []string{}}}
	got, err := EncodeHeader(h)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"boost":{"governed":[],"terms":[{"canonical":"C&D","entry_id":"e"}]},"job":17,"sample_count":1,"type":"recognize"}`
	if string(got) != want {
		t.Fatalf("got %s", got)
	}
}

func TestRoundTripEveryMessage(t *testing.T) {
	ms := 142
	samples := []float32{0, 0.5, -0.25, 1}
	for _, tc := range []struct {
		h       Header
		payload []byte
	}{
		{Header{Type: TypeReady, Protocol: ProtocolVersion, Model: testModel("ctc110m-v1")}, nil},
		{Header{Type: TypeReady, Protocol: ProtocolVersion, Model: testModel("")}, nil},
		{Header{Type: TypeUnavailable, Reason: "model_missing"}, nil},
		{Header{Type: TypeRecognize, Job: 1, SampleCount: 4}, EncodeSamples(samples)},
		{Header{Type: TypeShutdown}, nil},
		{Header{Type: TypeResult, Job: 1, Window: json.RawMessage(`{"text":"x"}`), RecognitionMS: &ms}, nil},
		{Header{Type: TypeError, Job: 1, Code: "failed"}, nil},
		{Header{Type: TypeState, State: "active"}, nil},
	} {
		data, err := EncodeFrame(tc.h, tc.payload)
		if err != nil {
			t.Fatal(tc.h.Type, err)
		}
		r := bytes.NewReader(data)
		f, err := ReadFrame(r)
		if err != nil {
			t.Fatal(tc.h.Type, err)
		}
		if f.Header.Type != tc.h.Type || !bytes.Equal(f.Payload, tc.payload) || r.Len() != 0 {
			t.Fatalf("%s: %+v", tc.h.Type, f)
		}
		if _, err := ReadFrame(r); err != io.EOF {
			t.Fatalf("clean end: %v", err)
		}
	}
	got, err := DecodeSamples(EncodeSamples(samples))
	if err != nil || len(got) != 4 || got[1] != 0.5 || got[2] != -0.25 {
		t.Fatal(got, err)
	}
	if _, err := DecodeSamples([]byte{1, 2, 3}); err == nil {
		t.Fatal("odd payload decoded")
	}
}

func TestMalformedFramesAreFatal(t *testing.T) {
	recognize := func(count int, payload int) []byte {
		h := `{"job":1,"sample_count":` + itoa(count) + `,"type":"recognize"}`
		return frame(h, make([]byte, payload))
	}
	big := make([]byte, 4)
	binary.BigEndian.PutUint32(big, MaxHeaderBytes+1)
	for name, data := range map[string][]byte{
		"empty header":             frame("", nil),
		"header too large":         append(big, bytes.Repeat([]byte(" "), 16)...),
		"truncated length":         {0, 0},
		"truncated header":         frame(`{"type":"shutdown"}`, nil)[:10],
		"truncated payload len":    frame(`{"type":"shutdown"}`, nil)[:4+19+2],
		"truncated payload":        recognize(4, 16)[:30],
		"not json":                 frame(`{"type":`, nil),
		"not object":               frame(`[1]`, nil),
		"trailing data":            frame(`{"type":"shutdown"} {}`, nil),
		"invalid utf8":             frame("{\"type\":\"state\",\"state\":\"\xff\"}", nil),
		"unknown type":             frame(`{"type":"hello"}`, nil),
		"wrong field type":         frame(`{"type":"recognize","job":"1","sample_count":1}`, append([]byte(nil), 0, 0, 0, 0)),
		"payload mismatch":         recognize(4, 12),
		"sample count zero":        recognize(0, 0),
		"sample count over":        recognize(MaxSampleCount+1, 0),
		"payload on shutdown":      frame(`{"type":"shutdown"}`, []byte{1}),
		"recognize no job":         frame(`{"sample_count":1,"type":"recognize"}`, make([]byte, 4)),
		"ready wrong protocol":     frame(`{"model":{"engine":"e","manifest_hash":"h","model_id":"m","model_revision":"r","sdk":"s","worker_build":"b"},"protocol":2,"type":"ready"}`, nil),
		"ready no model":           frame(`{"protocol":1,"type":"ready"}`, nil),
		"ready model missing id":   frame(`{"model":{"engine":"e","manifest_hash":"h","model_revision":"r","sdk":"s","worker_build":"b"},"protocol":1,"type":"ready"}`, nil),
		"unavailable no reason":    frame(`{"type":"unavailable"}`, nil),
		"result no window":         frame(`{"job":1,"recognition_ms":1,"type":"result"}`, nil),
		"result window not obj":    frame(`{"job":1,"recognition_ms":1,"type":"result","window":3}`, nil),
		"result no ms":             frame(`{"job":1,"type":"result","window":{}}`, nil),
		"error unknown code":       frame(`{"code":"boom","job":1,"type":"error"}`, nil),
		"state unknown":            frame(`{"state":"idle","type":"state"}`, nil),
		"payload length too large": frame(`{"type":"shutdown"}`, nil)[:4+19],
	} {
		if name == "payload length too large" {
			data = append(data, 0xff, 0xff, 0xff, 0xff)
		}
		_, err := ReadFrame(bytes.NewReader(data))
		if !errors.Is(err, ErrMalformedFrame) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestEncoderRefusesInvalidFrames(t *testing.T) {
	for name, tc := range map[string]struct {
		h       Header
		payload []byte
	}{
		"mismatch":     {Header{Type: TypeRecognize, Job: 1, SampleCount: 2}, make([]byte, 4)},
		"zero samples": {Header{Type: TypeRecognize, Job: 1}, nil},
		"too many":     {Header{Type: TypeRecognize, Job: 1, SampleCount: MaxSampleCount + 1}, make([]byte, 4*(MaxSampleCount+1))},
		"unknown":      {Header{Type: "hello"}, nil},
		"huge header":  {Header{Type: TypeRecognize, Job: 1, SampleCount: 1, Boost: &Boost{Governed: []string{strings.Repeat("a", MaxHeaderBytes)}}}, make([]byte, 4)},
	} {
		if _, err := EncodeFrame(tc.h, tc.payload); err == nil {
			t.Errorf("%s: encoded", name)
		}
	}
	if _, err := EncodeFrame(Header{Type: TypeRecognize, Job: 1, SampleCount: 1, Boost: &Boost{Governed: []string{strings.Repeat("a", MaxHeaderBytes)}}}, make([]byte, 4)); !errors.Is(err, ErrHeaderTooLarge) {
		t.Fatal(err)
	}
	max, err := EncodeFrame(Header{Type: TypeRecognize, Job: 1, SampleCount: MaxSampleCount}, make([]byte, 4*MaxSampleCount))
	if err != nil {
		t.Fatal(err)
	}
	if f, err := ReadFrame(bytes.NewReader(max)); err != nil || len(f.Payload) != 4*MaxSampleCount {
		t.Fatal(err)
	}
}

func testModel(booster string) *ModelIdentity {
	return &ModelIdentity{Engine: "FluidAudio", ModelID: "parakeet-tdt-0.6b-v3", ModelRevision: "rev-1", ManifestHash: "sha256-0011223344556677", SDK: "0.15.7", Booster: booster, WorkerBuild: "test-1"}
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

// Shared byte fixtures for the Swift framing tests (T058) and this package.

type frameFixture struct {
	File      string          `json:"file"`
	Valid     bool            `json:"valid"`
	Direction string          `json:"direction"`
	Header    json.RawMessage `json:"header,omitempty"`
	HeaderRaw string          `json:"header_json,omitempty"`
	Payload   *string         `json:"payload_hex,omitempty"`
	Samples   []float32       `json:"samples,omitempty"`
	Error     string          `json:"error,omitempty"`
	Note      string          `json:"note,omitempty"`
	data      []byte
}

type frameManifest struct {
	Description    string         `json:"description"`
	Framing        string         `json:"framing"`
	HeaderEncoding string         `json:"header_encoding"`
	MaxHeaderBytes int            `json:"max_header_bytes"`
	MaxSampleCount int            `json:"max_sample_count"`
	Update         string         `json:"update"`
	Frames         []frameFixture `json:"frames"`
}

func fixtureSet(t *testing.T) (frameManifest, []frameFixture) {
	t.Helper()
	ms := 142
	samples := []float32{0, 0.5, -0.25, 1}
	boost := &Boost{Terms: []BoostTerm{{EntryID: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", Canonical: "Zabbix"}}, Governed: []string{"zabix"}}
	window := json.RawMessage(`{"boost_hints":[{"canonical":"Zabbix","entry_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","source":"zabix"}],"evidence":{"padded_samples":239360,"samples":239360,"text":"check zabbix","timings_available":true,"tokens":[{"end":{"value":0.4},"start":{"value":0.12},"text":"check"}]},"sample_count":239360,"text":"check Zabbix","tokens":[{"end":0.4,"start":0.12,"text":"check"}]}`)
	valid := []struct {
		file, dir string
		h         Header
		samples   []float32
	}{
		{"ready.bin", "worker_to_flowd", Header{Type: TypeReady, Protocol: ProtocolVersion, Model: testModel("ctc110m-v1")}, nil},
		{"ready-no-booster.bin", "worker_to_flowd", Header{Type: TypeReady, Protocol: ProtocolVersion, Model: testModel("")}, nil},
		{"unavailable.bin", "worker_to_flowd", Header{Type: TypeUnavailable, Reason: "model_missing"}, nil},
		{"recognize.bin", "flowd_to_worker", Header{Type: TypeRecognize, Job: 17, SampleCount: 4, Boost: boost}, samples},
		{"recognize-no-boost.bin", "flowd_to_worker", Header{Type: TypeRecognize, Job: 18, SampleCount: 4}, samples},
		{"shutdown.bin", "flowd_to_worker", Header{Type: TypeShutdown}, nil},
		{"result.bin", "worker_to_flowd", Header{Type: TypeResult, Job: 17, Window: window, RecognitionMS: &ms}, nil},
		{"error.bin", "worker_to_flowd", Header{Type: TypeError, Job: 18, Code: "invalid_audio"}, nil},
		{"state.bin", "worker_to_flowd", Header{Type: TypeState, State: "active"}, nil},
	}
	var frames []frameFixture
	for _, v := range valid {
		var payload []byte
		if v.samples != nil {
			payload = EncodeSamples(v.samples)
		}
		data, err := EncodeFrame(v.h, payload)
		if err != nil {
			t.Fatal(v.file, err)
		}
		header, err := EncodeHeader(v.h)
		if err != nil {
			t.Fatal(err)
		}
		p := hex.EncodeToString(payload)
		frames = append(frames, frameFixture{File: v.file, Valid: true, Direction: v.dir, Header: header, HeaderRaw: string(header), Payload: &p, Samples: v.samples, data: data})
	}
	// Invalid frames. Each has exactly one defect.
	oversized := `{"type":"shutdown"}` + strings.Repeat(" ", MaxHeaderBytes+1-len(`{"type":"shutdown"}`))
	shortRead := frame(`{"job":19,"sample_count":4,"type":"recognize"}`, EncodeSamples(samples))
	shortRead = shortRead[:len(shortRead)-3]
	mismatch := frame(`{"job":20,"sample_count":4,"type":"recognize"}`, EncodeSamples(samples[:3]))
	over := frame(`{"job":21,"sample_count":239361,"type":"recognize"}`, nil)
	frames = append(frames,
		frameFixture{File: "invalid-oversized-header.bin", Direction: "any", Error: "header_too_large", Note: "header_length is 65,537; the header is valid JSON padded with spaces and payload_length is 0", data: frame(oversized, nil)},
		frameFixture{File: "invalid-short-read.bin", Direction: "flowd_to_worker", Error: "short_read", Note: "recognize of 4 samples whose payload stops 3 bytes early", data: shortRead},
		frameFixture{File: "invalid-payload-mismatch.bin", Direction: "flowd_to_worker", Error: "payload_length_mismatch", Note: "sample_count 4 with payload_length 12", data: mismatch},
		frameFixture{File: "invalid-sample-count-over.bin", Direction: "flowd_to_worker", Error: "sample_count_out_of_range", Note: "sample_count 239,361 with payload_length 0", data: over},
	)
	m := frameManifest{
		Description:    "Speech worker IPC frames shared by server/internal/speech/ipc_test.go and apps/macos/LocalFlowTests/SpeechWorkerFramingTests.swift. See specs/014-remote-dictation-server/contracts/speech-worker-ipc.md.",
		Framing:        "header_length (u32 BE) | header (UTF-8 JSON, 1...65,536 bytes) | payload_length (u32 BE) | payload",
		HeaderEncoding: "Compact JSON: no whitespace, object keys sorted by byte order at every level (Swift: JSONEncoder .sortedKeys + .withoutEscapingSlashes), no HTML escaping. Values avoid characters encoders escape differently, so encoders that sort keys reproduce header_json byte for byte; others should compare the decoded header object. Recognize payloads are Float32 little-endian.",
		MaxHeaderBytes: MaxHeaderBytes,
		MaxSampleCount: MaxSampleCount,
		Update:         "cd server && go test ./internal/speech -run TestWorkerFrameFixtures -update",
		Frames:         frames,
	}
	return m, frames
}

func TestWorkerFrameFixtures(t *testing.T) {
	m, frames := fixtureSet(t)
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(m); err != nil {
		t.Fatal(err)
	}
	manifest := buf.Bytes()
	if *update {
		if err := os.MkdirAll(fixtureDir, 0o755); err != nil {
			t.Fatal(err)
		}
		for _, f := range frames {
			if err := os.WriteFile(filepath.Join(fixtureDir, f.File), f.data, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.WriteFile(filepath.Join(fixtureDir, "manifest.json"), manifest, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	onDisk, err := os.ReadFile(filepath.Join(fixtureDir, "manifest.json"))
	if err != nil || !bytes.Equal(onDisk, manifest) {
		t.Fatalf("manifest.json does not reproduce (run with -update): %v", err)
	}
	for _, f := range frames {
		data, err := os.ReadFile(filepath.Join(fixtureDir, f.File))
		if err != nil || !bytes.Equal(data, f.data) {
			t.Fatalf("%s does not reproduce (run with -update): %v", f.File, err)
		}
		got, err := ReadFrame(bytes.NewReader(data))
		if !f.Valid {
			if !errors.Is(err, ErrMalformedFrame) {
				t.Fatalf("%s: %v", f.File, err)
			}
			continue
		}
		if err != nil {
			t.Fatalf("%s: %v", f.File, err)
		}
		reencoded, _ := EncodeHeader(got.Header)
		if string(reencoded) != f.HeaderRaw || hex.EncodeToString(got.Payload) != *f.Payload {
			t.Fatalf("%s: decoded %s", f.File, reencoded)
		}
		if f.Samples != nil {
			decoded, _ := DecodeSamples(got.Payload)
			for i := range decoded {
				if math.Float32bits(decoded[i]) != math.Float32bits(f.Samples[i]) {
					t.Fatalf("%s: sample %d", f.File, i)
				}
			}
		}
	}
}

// Feature 018 meeting worker frames (specs/018-one-server/contracts/meeting-worker-ipc.md).

func testMeetingModels() *MeetingModels {
	model := func(engine, id string) *MeetingModel {
		return &MeetingModel{Engine: engine, ModelID: id, ModelRevision: "rev-1", ManifestHash: "sha256-" + id}
	}
	voice := model("FluidAudio", "wespeaker")
	voice.Dimension = 256
	return &MeetingModels{Transcription: model("whisper.cpp", "whisper-turbo"), Diarization: model("FluidAudio", "pyannote"), Voice: voice}
}

func TestMeetingFramesRoundTrip(t *testing.T) {
	ms := 900
	speakers := 3
	for _, tc := range []struct {
		h       Header
		payload []byte
	}{
		{Header{Type: TypeReady, Protocol: ProtocolVersion, Models: testMeetingModels()}, nil},
		{Header{Type: TypeUnavailable, Reason: "model_missing", Missing: []string{"whisper-turbo"}}, nil},
		{Header{Type: TypeTranscribe, Job: 1, SampleCount: 2, Language: "auto", VocabularyTerms: []string{"Zabbix"}, Pipeline: "w120"}, make([]byte, 8)},
		{Header{Type: TypeDiarize, Job: 2, SampleCount: 1, NumSpeakers: &speakers}, make([]byte, 4)},
		{Header{Type: TypeEmbed, Job: 3, SampleCount: 48000}, make([]byte, 4*48000)},
		{Header{Type: TypeResult, Job: 1, Kind: TypeTranscribe, Result: json.RawMessage(`{"text":"x"}`), ProcessingMS: &ms}, nil},
		{Header{Type: TypeError, Job: 1, Code: CodeRepetition}, nil},
		{Header{Type: TypeState, State: "loading"}, nil},
	} {
		data, err := EncodeFrame(tc.h, tc.payload)
		if err != nil {
			t.Fatal(tc.h.Type, err)
		}
		f, err := ReadFrame(bytes.NewReader(data))
		if err != nil || f.Header.Type != tc.h.Type || len(f.Payload) != len(tc.payload) {
			t.Fatal(tc.h.Type, err)
		}
	}
	header, _ := EncodeHeader(Header{Type: TypeDiarize, Job: 2, SampleCount: 1, NumSpeakers: &speakers})
	if string(header) != `{"job":2,"num_speakers":3,"sample_count":1,"type":"diarize"}` {
		t.Fatal(string(header))
	}
}

func TestMeetingFramesMalformed(t *testing.T) {
	for name, data := range map[string][]byte{
		"ready models without voice dimension": frame(`{"models":{"diarization":{"engine":"e","manifest_hash":"h","model_id":"m","model_revision":"r"},"transcription":{"engine":"e","manifest_hash":"h","model_id":"m","model_revision":"r"},"voice":{"engine":"e","manifest_hash":"h","model_id":"m","model_revision":"r"}},"protocol":1,"type":"ready"}`, nil),
		"ready models missing one":             frame(`{"models":{"transcription":{"engine":"e","manifest_hash":"h","model_id":"m","model_revision":"r"}},"protocol":1,"type":"ready"}`, nil),
		"transcribe over 120 s":                frame(`{"job":1,"sample_count":1920001,"type":"transcribe"}`, nil),
		"diarize over 10 min":                  frame(`{"job":1,"sample_count":9600001,"type":"diarize"}`, nil),
		"embed under 3 s":                      frame(`{"job":1,"sample_count":47999,"type":"embed"}`, make([]byte, 4*47999)),
		"embed payload mismatch":               frame(`{"job":1,"sample_count":48000,"type":"embed"}`, make([]byte, 4)),
		"result unknown kind":                  frame(`{"job":1,"kind":"recognize","processing_ms":1,"result":{},"type":"result"}`, nil),
		"result kind without processing_ms":    frame(`{"job":1,"kind":"embed","result":{},"type":"result"}`, nil),
		"result kind result not object":        frame(`{"job":1,"kind":"embed","processing_ms":1,"result":[],"type":"result"}`, nil),
	} {
		if _, err := ReadFrame(bytes.NewReader(data)); !errors.Is(err, ErrMalformedFrame) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

// A meeting payload is converted from s16le to f32le while it is written, in
// bounded chunks, so no f32 copy of the whole payload exists (a diarization
// payload would be 38.4 MB).
func TestWriteS16AsF32Streams(t *testing.T) {
	const n = 100000
	s16 := make([]byte, 2*n)
	values := []int16{0, 16384, -16384, math.MaxInt16, math.MinInt16}
	for i := range n {
		binary.LittleEndian.PutUint16(s16[2*i:], uint16(values[i%len(values)]))
	}
	w := &chunkRecorder{}
	if err := WriteS16AsF32(w, s16); err != nil {
		t.Fatal(err)
	}
	if w.largest > s16ChunkSamples*4 || w.out.Len() != 4*n {
		t.Fatalf("largest write %d, total %d", w.largest, w.out.Len())
	}
	got, _ := DecodeSamples(w.out.Bytes())
	for i, want := range []float32{0, 0.5, -0.5, 32767.0 / 32768, -1} {
		if got[i] != want || got[i+len(values)] != want {
			t.Fatalf("sample %d: %v, want %v", i, got[i], want)
		}
	}
	allocs := testing.AllocsPerRun(5, func() { _ = WriteS16AsF32(io.Discard, s16) })
	if allocs > 1 {
		t.Fatalf("%v allocations per conversion", allocs)
	}
}

type chunkRecorder struct {
	out     bytes.Buffer
	largest int
}

func (c *chunkRecorder) Write(p []byte) (int, error) {
	c.largest = max(c.largest, len(p))
	return c.out.Write(p)
}
