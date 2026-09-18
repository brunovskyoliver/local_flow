package prompts

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

// Opt-in regression against flowd and its real inference backend. A fake model
// cannot prove that wording changes correct this model-dependent behavior.
// Run with LOCALFLOW_REWRITE_TEST_ENDPOINT=http://127.0.0.1:8080.
func TestLiveCleanSpokenEmail(t *testing.T) {
	endpoint := os.Getenv("LOCALFLOW_REWRITE_TEST_ENDPOINT")
	if endpoint == "" {
		t.Skip("requires an explicitly configured live rewrite server")
	}
	client := &http.Client{Timeout: 25 * time.Second}
	for _, tc := range []struct{ name, input, want string }{
		{"spoken", "Please email dev at example.com on Monday at 9:30.", "dev@example.com"},
		{"literal", "Please email dev@example.com on Monday at 9:30.", "dev@example.com"},
		{"ordinary_at", "Please meet the dev at the office on Monday at 9:30.", "at the office"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body, _ := json.Marshal(map[string]any{"schema_version": 1, "request_id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "mode": "clean", "text": tc.input, "language_hints": []string{}, "stream_deltas": false})
			req, err := http.NewRequest("POST", strings.TrimRight(endpoint, "/")+"/v1/rewrite", bytes.NewReader(body))
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set("Content-Type", "application/json")
			if token := os.Getenv("LOCALFLOW_REWRITE_TOKEN"); token != "" {
				req.Header.Set("Authorization", "Bearer "+token)
			}
			resp, err := client.Do(req)
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
				if event.Event == "error" {
					t.Fatal(event.Code)
				}
				if event.Event == "result" {
					if !strings.Contains(event.Text, tc.want) || !strings.Contains(event.Text, "Monday") || !strings.Contains(event.Text, "9:30") {
						t.Fatalf("Clean output did not preserve/format expected details: %q", event.Text)
					}
					if tc.name == "ordinary_at" && strings.Contains(event.Text, "@") {
						t.Fatalf("invented address: %q", event.Text)
					}
					return
				}
			}
			t.Fatal("missing result")
		})
	}
}
