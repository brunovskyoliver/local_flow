package rewrite

import (
	"context"
	"strings"
	"testing"

	"localflow/server/internal/backend"
	"localflow/server/internal/rewrite/prompts"
)

// scripted returns its outputs in order and records what each call sent.
type scripted struct {
	outputs         []string
	systems, inputs []string
}

func (s *scripted) Probe(context.Context) backend.Info {
	return backend.Info{State: "ready", Model: "test"}
}
func (s *scripted) Generate(_ context.Context, in backend.Input) (backend.Completion, error) {
	s.systems = append(s.systems, in.System)
	s.inputs = append(s.inputs, in.Text)
	out := s.outputs[min(len(s.systems), len(s.outputs))-1]
	return backend.Completion{Text: out, Model: "test", DurationMS: 5}, nil
}

func TestSpokenRulesOnlyForDisfluentSpeech(t *testing.T) {
	template, _ := prompts.For("clean")
	for _, tc := range []struct {
		input, sent string
		spoken      bool
	}{
		{"Please redeploy the app.", "Please redeploy the app.", false},
		{"Uh please redeploy the app.", "Please redeploy the app.", true},
		{"Deploy it on Tuesday, no, Wednesday.", "Deploy it on Tuesday, no, Wednesday.", true},
	} {
		b := &scripted{outputs: []string{tc.sent}}
		post(t, NewHandler(HandlerConfig{Backend: b, Shield: true}), testBody(tc.input), "")
		want := template.Text
		if tc.spoken {
			want = prompts.WithSpoken(template.Text)
		}
		if len(b.systems) != 1 || b.systems[0] != want || b.inputs[0] != tc.sent {
			t.Errorf("%q: sent %q with spoken rules=%v", tc.input, b.inputs, tc.spoken)
		}
	}
}

// An output that fails validation under the spoken rules is regenerated once
// with the plain template; the plain template gets no second chance.
func TestSpokenRetryUsesPlainTemplate(t *testing.T) {
	template, _ := prompts.For("clean")
	input := "Send the draft to Peter, sorry, to Martin. I'm getting this error when trying to generate the summary of the meeting."
	for _, tc := range []struct {
		name    string
		outputs []string
		calls   int
		want    string
	}{
		{"half-applied correction", []string{"Send the draft to Peter, to Martin. I'm getting this error when trying to generate the summary of the meeting.", "Send the draft to Peter, sorry, to Martin. I'm getting this error when generating the meeting summary."}, 2, "Send the draft to Peter, sorry, to Martin. I'm getting this error when generating the meeting summary."},
		{"dropped sentence", []string{"Send the draft to Martin.", "Send the draft to Martin. I'm getting this error when trying to generate the summary of the meeting."}, 2, "Send the draft to Martin. I'm getting this error when trying to generate the summary of the meeting."},
		{"valid first time", []string{"Send the draft to Martin. I'm getting this error when trying to generate the summary of the meeting."}, 1, "Send the draft to Martin. I'm getting this error when trying to generate the summary of the meeting."},
		{"both invalid", []string{"Send the draft to Peter, to Martin.", "Send the draft to Peter, to Martin."}, 2, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := &scripted{outputs: tc.outputs}
			w := post(t, NewHandler(HandlerConfig{Backend: b, Shield: true}), testBody(input), "")
			if len(b.systems) != tc.calls || b.systems[0] != prompts.WithSpoken(template.Text) || (tc.calls == 2 && b.systems[1] != template.Text) {
				t.Fatalf("calls: %d", len(b.systems))
			}
			if tc.want == "" {
				if !strings.Contains(w.Body.String(), string(CodeBackendError)) {
					t.Fatal(w.Body.String())
				}
				return
			}
			result := resultLine(t, w.Body.String())
			if result["text"] != tc.want {
				t.Fatalf("%v", result["text"])
			}
			if ms := result["timing"].(map[string]any)["backend_ms"]; ms != float64(5*tc.calls) {
				t.Fatalf("backend_ms %v covers every attempt", ms)
			}
		})
	}
}

// Polished and concise may merge or drop sentences; only clean is held to
// keeping every one.
func TestSentenceGuardOnlyForClean(t *testing.T) {
	input := "Uh I'm getting this error when trying to generate the summary. Please check the logs."
	b := &scripted{outputs: []string{"Please check the logs for the summary error."}}
	body := strings.Replace(testBody(input), `"clean"`, `"concise"`, 1)
	w := post(t, NewHandler(HandlerConfig{Backend: b, Shield: true}), body, "")
	if len(b.systems) != 1 || resultLine(t, w.Body.String())["text"] != "Please check the logs for the summary error." {
		t.Fatalf("calls %d: %s", len(b.systems), w.Body.String())
	}
}
