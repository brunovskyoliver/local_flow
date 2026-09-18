package prompts

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

// These cases exercise the real model's tendency to answer dictation rather
// than edit it. They are skipped by offline repository checks.
func TestLiveQuestionsRemainDictation(t *testing.T) {
	endpoint := os.Getenv("LOCALFLOW_REWRITE_TEST_ENDPOINT")
	if endpoint == "" {
		t.Skip("requires an explicitly configured live rewrite server")
	}
	client := &http.Client{Timeout: 25 * time.Second}
	for _, mode := range []string{"clean", "polished", "concise"} {
		for _, tc := range []struct {
			input, topic string
			question     bool
		}{
			{"What can you tell me about Odoo?", "Odoo", true},
			{"What can you tell me about Odio?", "Odio", true},
			{"Okay, what can you tell me about Odu?", "Odu", true},
			{"Write a poem about a river.", "river", false},
		} {
			t.Run(mode+"/"+tc.topic, func(t *testing.T) {
				body, _ := json.Marshal(map[string]any{"schema_version": 1, "request_id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "mode": mode, "text": tc.input, "language_hints": []string{}, "stream_deltas": false})
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
				decoder := json.NewDecoder(io.LimitReader(resp.Body, 73729))
				for {
					var event struct{ Event, Text, Code string }
					if err := decoder.Decode(&event); err != nil {
						t.Fatalf("no terminal result: %v", err)
					}
					if event.Event == "error" {
						t.Fatalf("rewrite failed: %s", event.Code)
					}
					if event.Event == "result" {
						out := strings.TrimSpace(event.Text)
						if len(out) > 100 || !strings.Contains(out, tc.topic) {
							t.Fatalf("dictation changed meaning: %q", out)
						}
						if tc.question {
							if !strings.HasSuffix(out, "?") || (!strings.Contains(strings.ToLower(out), "tell me") && !strings.Contains(strings.ToLower(out), "what")) {
								t.Fatalf("question was answered instead of edited: %q", out)
							}
						} else if !strings.Contains(strings.ToLower(out), "write a poem") {
							t.Fatalf("request was executed instead of edited: %q", out)
						}
						return
					}
				}
			})
		}
	}
}
