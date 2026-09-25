package prompts

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

// Opt-in regression for the spoken-speech rules against flowd and its real
// model. Output varies by model, so only outcomes that must never happen fail
// the test outright: a correction applied halfway (marker gone, replaced value
// kept) and a lost detail in a case that only lists what must survive. Other
// misses are logged and fail the test only past 15% of the cases.
// Run with LOCALFLOW_REWRITE_TEST_ENDPOINT=http://127.0.0.1:8080.
func TestLiveDisfluency(t *testing.T) {
	endpoint := os.Getenv("LOCALFLOW_REWRITE_TEST_ENDPOINT")
	if endpoint == "" {
		t.Skip("requires an explicitly configured live rewrite server")
	}
	data, err := os.ReadFile("../../../../fixtures/rewrite/disfluency-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			ID, Input, Marker string
			Must              []string
			MustNot           []string `json:"must_not"`
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	match := func(pattern, text string) bool { return regexp.MustCompile("(?i)" + pattern).MatchString(text) }
	misses := 0
	for _, c := range fixture.Cases {
		text, code := liveRewrite(t, endpoint, c.Input)
		if code != "" {
			// A rejected rewrite leaves the dictation as spoken, which is safe.
			t.Logf("%s: rejected (%s)", c.ID, code)
			misses++
			continue
		}
		var problems []string
		for _, p := range c.Must {
			if !match(p, text) {
				problems = append(problems, "missing /"+p+"/")
			}
		}
		kept := false
		for _, p := range c.MustNot {
			if match(p, text) {
				kept = true
				problems = append(problems, "contains /"+p+"/")
			}
		}
		switch {
		case c.Marker != "" && kept && !match(c.Marker, text):
			t.Errorf("%s: correction applied halfway: %q", c.ID, text)
		case len(c.MustNot) == 0 && len(problems) > 0:
			t.Errorf("%s: lost content %v: %q", c.ID, problems, text)
		case len(problems) > 0:
			t.Logf("%s: %v: %q", c.ID, problems, text)
			misses++
		}
	}
	if limit := len(fixture.Cases) * 15 / 100; misses > limit {
		t.Errorf("%d of %d cases missed, limit %d", misses, len(fixture.Cases), limit)
	}
}

func liveRewrite(t *testing.T, endpoint, input string) (text, code string) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"schema_version": 1, "request_id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "mode": "clean", "text": input, "language_hints": []string{}, "stream_deltas": false})
	req, err := http.NewRequest("POST", strings.TrimRight(endpoint, "/")+"/v1/rewrite", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token := os.Getenv("LOCALFLOW_REWRITE_TOKEN"); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := (&http.Client{Timeout: 25 * time.Second}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("HTTP %d", resp.StatusCode)
	}
	decoder := json.NewDecoder(http.MaxBytesReader(nil, resp.Body, 73728))
	for decoder.More() {
		var event struct{ Event, Text, Code string }
		if err := decoder.Decode(&event); err != nil {
			t.Fatal(err)
		}
		switch event.Event {
		case "error":
			return "", event.Code
		case "result":
			return event.Text, ""
		}
	}
	t.Fatal("missing result")
	return "", ""
}
