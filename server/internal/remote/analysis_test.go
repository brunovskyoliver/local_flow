package remote

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"localflow/server/internal/analysis"
)

// fakeAnalysis decodes with the analysis protocol's own rules and emits
// scripted event lines; with hold set it waits for it first.
type fakeAnalysis struct {
	lines     [][]byte
	hold      chan struct{}
	seen      chan *analysis.Request
	cancelled atomic.Int32
}

func newFakeAnalysis(lines ...string) *fakeAnalysis {
	f := &fakeAnalysis{seen: make(chan *analysis.Request, 64)}
	for _, line := range lines {
		f.lines = append(f.lines, []byte(line))
	}
	return f
}

func (f *fakeAnalysis) DecodeRequest(body []byte) (*analysis.Request, error) {
	return analysis.DecodeRequestBytes(body, analysis.MaxRequestBodyBytes)
}

func (f *fakeAnalysis) Run(ctx context.Context, req *analysis.Request, emit func([]byte) error) analysis.Code {
	f.seen <- req
	if f.hold != nil {
		select {
		case <-f.hold:
		case <-ctx.Done():
			f.cancelled.Add(1)
			return analysis.RunCancelled
		}
	}
	for _, line := range f.lines {
		if emit(append(append([]byte(nil), line...), '\n')) != nil {
			return analysis.RunCancelled
		}
	}
	return ""
}

func analysisUUID(i int) string { return fmt.Sprintf("bbbb%04x-0000-4000-8000-%012d", i, i) }

// analysisRequest is a valid analysis request of about segments × 530 bytes.
func analysisRequest(t *testing.T, segments int, extra map[string]any) []byte {
	t.Helper()
	list := make([]any, segments)
	for i := range list {
		list[i] = map[string]any{"id": analysisUUID(i + 2), "start_ms": i * 1000, "end_ms": i*1000 + 1000,
			"speaker_id": nil, "text": strings.Repeat("Ahoj všetci. ", 40)}
	}
	body := map[string]any{
		"schema_version": 1, "request_id": analysisUUID(0x100), "run_id": analysisUUID(0x200),
		"priority": "background", "stage": "full",
		"meeting": map[string]any{"id": analysisUUID(0xf00d), "title": "Sync", "started_at": "2026-09-20T09:00:00+02:00",
			"duration_ms": 60000, "time_zone": "Europe/Bratislava", "language_policy": map[string]any{"output": "sk", "preserve_terms": true}},
		"participants": []any{}, "segments": list, "notes": []any{},
	}
	for key, value := range extra {
		body[key] = value
	}
	return mustJSON(t, body)
}

func hexSHA256(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// sendAnalysis sends body as analysis_part fragments of at most size bytes
// and closes it.
func (c *testClient) sendAnalysis(op int64, body []byte, size int) {
	parts := 0
	for rest := body; len(rest) > 0; parts++ {
		n := min(size, len(rest))
		for n < len(rest) && rest[n]&0xc0 == 0x80 {
			n--
		}
		c.send(AnalysisPart{Op: op, Index: parts, Data: string(rest[:n])})
		rest = rest[n:]
	}
	c.send(Analysis{Op: op, Parts: parts, Bytes: len(body), SHA256: hexSHA256(body)})
}

// analysisEvents reads op's events up to the terminal one, reassembling
// fragments, and reports how many fragments arrived.
func (c *testClient) analysisEvents(op int64) (events [][]byte, fragments int) {
	c.t.Helper()
	var pending []byte
	for {
		switch m := c.recv().(type) {
		case AnalysisEventPart:
			if m.Op != op || m.Index != fragments {
				c.t.Fatalf("fragment %#v", m)
			}
			pending = append(pending, m.Data...)
			fragments++
		case AnalysisEvent:
			line := []byte(m.Event)
			if len(m.Event) == 0 {
				if m.Parts != fragments || m.SHA256 != hexSHA256(pending) {
					c.t.Fatalf("close %d parts %s for %d fragments", m.Parts, m.SHA256, fragments)
				}
				line, pending = pending, nil
			}
			events = append(events, line)
			var kind struct{ Type string }
			if json.Unmarshal(line, &kind) != nil {
				c.t.Fatalf("event not JSON: %d bytes", len(line))
			}
			if kind.Type == "result" || kind.Type == "error" {
				return events, fragments
			}
		default:
			c.t.Fatalf("got %#v", m)
		}
	}
}

type analysisHarness struct {
	*harness
	runner   *fakeAnalysis
	analyzer *Analyzer
}

func newAnalysisHarness(t *testing.T, runner *fakeAnalysis) *analysisHarness {
	t.Helper()
	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	a := NewAnalyzer(AnalysisConfig{Runner: runner, Logger: h.listener.cfg.Logger})
	operations[PurposeSession]["analysis"] = a.Start
	return &analysisHarness{h, runner, a}
}

// waitReleased waits until the analyzer holds no assembly bytes and no user
// slot.
func (h *analysisHarness) waitReleased(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for (h.analyzer.buffered.Load() != 0 || h.analyzer.inFlight() != 0) && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if n, users := h.analyzer.buffered.Load(), h.analyzer.inFlight(); n != 0 || users != 0 {
		t.Fatalf("%d bytes buffered, %d slots held", n, users)
	}
}

const acceptedLine = `{"schema_version":1,"type":"accepted","request_id":"bbbb0100-0000-4000-8000-000000000256","server":{"name":"flowd","version":"x"}}`

// Feature 018 T029: a request larger than one control message arrives in
// order and reaches the runner whole; an event line too large for one
// control message goes out as fragments of at most 49,152 bytes closed by
// analysis_event with parts and sha256; the op ends after the terminal
// event, and logs carry no request or event content.
func TestAnalysisOperation(t *testing.T) {
	// A result line of about 90 KB with characters JSON escapes (<, ", \)
	// and multi-byte UTF-8, so fragments must be cut by encoded size and on
	// rune boundaries.
	result := `{"schema_version":1,"type":"result","request_id":"bbbb0100-0000-4000-8000-000000000256","notes":"` +
		strings.Repeat(`<ž> \"Zabbix\" `, 6000) + `"}`
	runner := newFakeAnalysis(acceptedLine, `{"schema_version":1,"type":"progress","request_id":"x","stage":"full","chars":10}`, result)
	h := newAnalysisHarness(t, runner)
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	body := analysisRequest(t, 300, nil)
	if len(body) <= MaxControlBytes || len(body) > MaxAnalysisBytes {
		t.Fatalf("request of %d bytes", len(body))
	}
	c.sendAnalysis(1, body, MaxAnalysisPartBytes)
	events, fragments := c.analysisEvents(1)
	if len(events) != 3 || string(events[0]) != acceptedLine || string(events[2]) != result || fragments < 2 {
		t.Fatalf("%d events, %d fragments", len(events), fragments)
	}
	if req := <-runner.seen; len(req.Segments) != 300 || req.RequestID != analysisUUID(0x100) {
		t.Fatalf("request %d segments", len(req.Segments))
	}
	h.waitReleased(t)
	// The op ended with the result: the next one starts on the same channel,
	// here a request that fits in one fragment.
	runner.lines = [][]byte{[]byte(acceptedLine), []byte(`{"schema_version":1,"type":"error","request_id":"x","code":"server_busy","message":"m"}`)}
	c.sendAnalysis(2, analysisRequest(t, 1, nil), MaxAnalysisPartBytes)
	if events, fragments := c.analysisEvents(2); len(events) != 2 || fragments != 0 {
		t.Fatalf("%d events, %d fragments", len(events), fragments)
	}
	h.waitReleased(t)
	logs := h.logs.String()
	if !strings.Contains(logs, "remote analysis channel=") || strings.Contains(logs, "Ahoj") ||
		strings.Contains(logs, "Zabbix") || strings.Contains(logs, "Sync") {
		t.Fatalf("logs: %s", logs)
	}
}

// Assembly refusals end the op with invalid_message, limit_exceeded or
// unsupported_version, free the buffer and the user's slot, and leave the
// channel open. A client-supplied primary server is not a request field, so
// it is refused like any unknown field (research R9).
func TestAnalysisAssemblyRefusals(t *testing.T) {
	h := newAnalysisHarness(t, newFakeAnalysis(acceptedLine, `{"schema_version":1,"type":"result","request_id":"x"}`))
	_, _, token := h.approved("a", 1)
	body := analysisRequest(t, 10, nil)
	sum := hexSHA256(body)
	half := len(body) / 2
	first := AnalysisPart{Op: 1, Index: 0, Data: string(body[:half])}
	second := AnalysisPart{Op: 1, Index: 1, Data: string(body[half:])}
	big := strings.Repeat("a", MaxAnalysisPartBytes)
	for name, tc := range map[string]struct {
		frames []Frame
		code   ErrorCode
	}{
		"fragment out of order": {[]Frame{control(t, first), control(t, AnalysisPart{Op: 1, Index: 2, Data: "x"})}, CodeInvalidMessage},
		"parts mismatch": {[]Frame{control(t, first), control(t, second),
			control(t, Analysis{Op: 1, Parts: 3, Bytes: len(body), SHA256: sum})}, CodeInvalidMessage},
		"bytes mismatch": {[]Frame{control(t, first), control(t, second),
			control(t, Analysis{Op: 1, Parts: 2, Bytes: len(body) - 1, SHA256: sum})}, CodeInvalidMessage},
		"sha256 mismatch": {[]Frame{control(t, first), control(t, second),
			control(t, Analysis{Op: 1, Parts: 2, Bytes: len(body), SHA256: strings.Repeat("0", 64)})}, CodeInvalidMessage},
		"over 262,144 bytes": {[]Frame{
			control(t, AnalysisPart{Op: 1, Index: 0, Data: big}), control(t, AnalysisPart{Op: 1, Index: 1, Data: big}),
			control(t, AnalysisPart{Op: 1, Index: 2, Data: big}), control(t, AnalysisPart{Op: 1, Index: 3, Data: big}),
			control(t, AnalysisPart{Op: 1, Index: 4, Data: big}), control(t, AnalysisPart{Op: 1, Index: 5, Data: big}),
		}, CodeLimitExceeded},
		"f32le audio during assembly":   {[]Frame{control(t, first), {KindAudio, make([]byte, 8)}}, CodeInvalidMessage},
		"s16le samples during assembly": {[]Frame{control(t, first), {KindSamples, make([]byte, 8)}}, CodeInvalidMessage},
		"another message type":          {[]Frame{control(t, first), control(t, MeetingCancel{Op: 1})}, CodeInvalidMessage},
	} {
		c, _ := h.hello(PurposeSession, token)
		for _, frame := range tc.frames {
			c.sendFrame(frame)
		}
		expectError(t, c.recv(), 1, tc.code)
		h.waitReleased(t)
		// The channel stays open for the next operation.
		c.sendAnalysis(2, body, MaxAnalysisPartBytes)
		if events, _ := c.analysisEvents(2); len(events) != 2 {
			t.Fatalf("%s: next op %d events", name, len(events))
		}
		c.ws.CloseNow()
	}
	for name, tc := range map[string]struct {
		body []byte
		code ErrorCode
	}{
		"primary server field (R9)": {analysisRequest(t, 1, map[string]any{"primary_url": "http://169.254.169.254/v1"}), CodeInvalidMessage},
		"newer request version":     {analysisRequest(t, 1, map[string]any{"schema_version": 2}), CodeUnsupportedVersion},
		"not JSON":                  {[]byte("{"), CodeInvalidMessage},
	} {
		c, _ := h.hello(PurposeSession, token)
		c.sendAnalysis(1, tc.body, MaxAnalysisPartBytes)
		if m := c.recv(); m.MessageType() != "error" || m.(ErrorMessage).Code != tc.code {
			t.Errorf("%s: %#v", name, m)
		}
		h.waitReleased(t)
		c.ws.CloseNow()
	}
	if len(h.runner.seen) != 8 {
		t.Fatalf("runner ran %d times, want only the 8 follow-up ops", len(h.runner.seen))
	}
}

// One analysis per user across channels (MaxAnalysesPerUser): a second is
// busy at its first fragment. Closing the channel cancels a running analysis
// and frees its slot; closing it mid-assembly frees the buffer.
func TestAnalysisBusyAndCancel(t *testing.T) {
	runner := newFakeAnalysis(acceptedLine, `{"schema_version":1,"type":"result","request_id":"x"}`)
	runner.hold = make(chan struct{})
	h := newAnalysisHarness(t, runner)
	_, _, token := h.approved("a", 1)
	_, _, other := h.approved("b", 2)
	c1, _ := h.hello(PurposeSession, token)
	c2, _ := h.hello(PurposeSession, token)
	body := analysisRequest(t, 1, nil)
	c1.sendAnalysis(1, body, MaxAnalysisPartBytes)
	<-runner.seen
	c2.send(AnalysisPart{Op: 1, Index: 0, Data: "{"})
	expectError(t, c2.recv(), 1, CodeBusy)
	// Another user is not affected.
	c3, _ := h.hello(PurposeSession, other)
	c3.send(AnalysisPart{Op: 1, Index: 0, Data: "{"})
	deadline := time.Now().Add(5 * time.Second)
	for (h.analyzer.inFlight() != 2 || h.analyzer.buffered.Load() != 1) && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if h.analyzer.inFlight() != 2 {
		t.Fatal("second user's analysis not admitted")
	}
	// Closing mid-assembly frees the buffer; closing the first channel
	// cancels its running analysis.
	c3.ws.CloseNow()
	c1.ws.CloseNow()
	h.waitReleased(t)
	if runner.cancelled.Load() != 1 {
		t.Fatal("running analysis not cancelled")
	}
	close(runner.hold)
	c2.sendAnalysis(2, body, MaxAnalysisPartBytes)
	if events, _ := c2.analysisEvents(2); len(events) != 2 {
		t.Fatalf("%d events", len(events))
	}
}

// repoFile is path relative to the repository root.
func repoFile(path string) string { return filepath.Join("..", "..", "..", path) }

// readFixture decodes a JSON fixture into v.
func readFixture(t *testing.T, path string, v any) {
	t.Helper()
	data, err := os.ReadFile(repoFile(path))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatal(err)
	}
}

// fixtureSegments is the segment text of fixtures/intelligence/english.json.
func fixtureSegments(t *testing.T) []string {
	t.Helper()
	var meeting struct {
		Segments []struct {
			Text string `json:"normalized_text"`
		} `json:"segments"`
	}
	readFixture(t, "fixtures/intelligence/english.json", &meeting)
	out := make([]string, len(meeting.Segments))
	for i, s := range meeting.Segments {
		out[i] = s.Text
	}
	return out
}

// scanLogs runs scripts/check-remote-logs.sh over text and returns its
// report; clean is false when it found anything (Feature 018 FR-029).
func scanLogs(t *testing.T, text string) (report string, clean bool) {
	t.Helper()
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 not found; the log scan needs it")
	}
	file := filepath.Join(t.TempDir(), "flowd.log")
	if err := os.WriteFile(file, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("bash", repoFile("scripts/check-remote-logs.sh"), file).CombinedOutput()
	if _, failed := err.(*exec.ExitError); err != nil && !failed {
		t.Fatal(err)
	}
	return string(out), err == nil
}

// The log scan finds each kind of content the new operations carry, so the
// clean scans below mean something.
func TestLogScanFindsContent(t *testing.T) {
	var manifest struct {
		Fixtures []struct {
			Reference string `json:"reference"`
		} `json:"fixtures"`
	}
	readFixture(t, "fixtures/audio/manifest.json", &manifest)
	payload := make([]byte, 48)
	_, _ = rand.Read(payload)
	lines := map[string]string{
		"transcript text":  "result " + manifest.Fixtures[0].Reference,
		"analysis text":    "summary: " + fixtureSegments(t)[0],
		"embedding vector": "centroid [0.123456 -0.5 0.25 1e-3]",
		"sample payload":   fmt.Sprintf("frame %v", payload),
	}
	lines["sample payload "] = "frame " + base64.StdEncoding.EncodeToString(append(payload, payload...))
	for kind, line := range lines {
		report, clean := scanLogs(t, "remote meeting channel=1 op=1 code=ok\n"+line+"\n")
		if clean || !strings.Contains(report, ":2: "+strings.TrimSpace(kind)) {
			t.Errorf("%s not found:\n%s", kind, report)
		}
	}
}

// FR-029: the analysis operation's log lines, and the analysis handler's
// own, carry no request or event text, over a request refused, one that
// runs on the server's backend, a busy one and a fragmented result.
func TestAnalysisLogsCarryNoContent(t *testing.T) {
	segments := fixtureSegments(t)
	list := make([]any, len(segments))
	for i, text := range segments {
		list[i] = map[string]any{"id": analysisUUID(i + 2), "start_ms": i * 1000, "end_ms": i*1000 + 1000, "speaker_id": nil, "text": text}
	}
	body := analysisRequest(t, 0, map[string]any{"segments": list})

	operations := Operations{PurposeSession: {}}
	h := newHarness(t, operations)
	handler := analysis.NewHandler(analysis.HandlerConfig{Backend: &echoBackend{}, Limits: analysis.DefaultLimits(), Logger: h.listener.cfg.Logger})
	a := NewAnalyzer(AnalysisConfig{Runner: handler, Clock: h.clock, Logger: h.listener.cfg.Logger})
	operations[PurposeSession]["analysis"] = a.Start
	_, _, token := h.approved("a", 1)
	c, _ := h.hello(PurposeSession, token)
	// The backend echoes its prompt, so the result fails validation.
	c.sendAnalysis(1, body, 64)
	c.analysisEvents(1)
	// A refused assembly.
	c.send(AnalysisPart{Op: 2, Index: 0, Data: string(body)})
	c.send(Analysis{Op: 2, Parts: 1, Bytes: len(body), SHA256: strings.Repeat("0", 64)})
	expectError(t, c.recv(), 2, CodeInvalidMessage)

	// A fragmented result and a busy second analysis, over a fake runner.
	result, _ := json.Marshal(map[string]any{"schema_version": 1, "type": "result", "request_id": "x",
		"summary": strings.Repeat(segments[0]+" ", 2*MaxAnalysisPartBytes/len(segments[0]))})
	runner := newFakeAnalysis(string(result))
	runner.hold = make(chan struct{})
	operations[PurposeSession]["analysis"] = NewAnalyzer(AnalysisConfig{Runner: runner, Clock: h.clock, Logger: h.listener.cfg.Logger}).Start
	c.sendAnalysis(3, body, MaxAnalysisPartBytes)
	other, _ := h.hello(PurposeSession, token)
	other.send(AnalysisPart{Op: 1, Index: 0, Data: string(body)})
	expectError(t, other.recv(), 1, CodeBusy)
	close(runner.hold)
	if _, fragments := c.analysisEvents(3); fragments < 2 {
		t.Fatalf("%d fragments", fragments)
	}

	logs := h.logs.String()
	if !strings.Contains(logs, "remote analysis") || !strings.Contains(logs, "request_id=") {
		t.Fatalf("missing log lines:\n%s", logs)
	}
	if report, clean := scanLogs(t, logs); !clean {
		t.Fatalf("log scan:\n%s", report)
	}
}
