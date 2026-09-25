package disfluency

import "testing"

func TestSignals(t *testing.T) {
	for _, tc := range []struct {
		text string
		want bool
	}{
		{"Also uh redeploy the app.", true},
		{"The app is like really slow, you know.", true},
		{"Meet on Tuesday, no, Wednesday.", true},
		{"Please run stage I mean phase eleven.", true},
		{"Je to proste pomalé.", true},
		{"Can you please find why were why are there three speakers?", true},
		{"Please get rid of the the scroll bar.", true},
		{"I need to c create a gzip file.", true},
		{"I want to I need to finish the script.", true},
		{"Please redeploy the app as well.", false},
		{"No, I don't want the dark theme.", false},
		{"Nastav timeout na 60 sekúnd a pošli mi výsledok.", false},
		{"Version 1.2.3 and 1.2.4 both fail.", false},
		{"I have a question about it.", false},
	} {
		if got := Signals(tc.text); got != tc.want {
			t.Errorf("Signals(%q) = %v", tc.text, got)
		}
	}
}

func TestHalfCorrected(t *testing.T) {
	for _, tc := range []struct {
		input, output string
		want          bool
	}{
		// Unsafe outputs the 4B model produced during evaluation.
		{"Send the draft to Peter, sorry, to Martin.", "Send the draft to Peter, to Martin.", true},
		{"Run npm install, sorry, pnpm install in the web folder.", "Run npm install, pnpm install in the web folder.", true},
		{"Please run stage I mean phase eleven.", "Please run stage, phase eleven.", true},
		{"Pošli to Jankovi, prepáč, Marekovi.", "Pošli to Jankovi, Marekovi.", true},
		{"Meet on Tuesday, no, Wednesday.", "Meet on Tuesday, Wednesday.", true},
		// Resolved, or left as spoken.
		{"Send the draft to Peter, sorry, to Martin.", "Send the draft to Martin.", false},
		{"Run npm install, sorry, pnpm install in the web folder.", "Run pnpm install in the web folder.", false},
		{"Send the draft to Peter, sorry, to Martin.", "Send the draft to Peter, sorry, to Martin.", false},
		{"Meet on Tuesday, no, Wednesday.", "Meet on Wednesday.", false},
		// Not corrections: sentence-initial markers and answers.
		{"Sorry, I was late. I mean it.", "I was late.", false},
		{"We ignore it. I mean we still use DHCP.", "We ignore it. We still use DHCP.", false},
		{"No, I don't want it.", "I don't want it.", false},
		{"Please wait for the build.", "Please wait for the build.", false},
	} {
		if got := HalfCorrected(tc.input, tc.output); got != tc.want {
			t.Errorf("HalfCorrected(%q, %q) = %v", tc.input, tc.output, got)
		}
	}
}

func TestDroppedSentence(t *testing.T) {
	in := "I'm getting this error when trying to generate summary out of this meeting. Please take a look at the DB state and the logs. Mm."
	if !DroppedSentence(in, "Please take a look at the DB state and the logs.") {
		t.Error("missed a dropped sentence")
	}
	for _, out := range []string{
		"I'm getting this error when trying to generate the summary of this meeting. Please take a look at the DB state and the logs.",
		// Fillers and short sentences may go; grammar may change word endings.
		"I got this error when I tried generating the summary of this meeting. Please look at the DB state and logs.",
	} {
		if DroppedSentence(in, out) {
			t.Errorf("flagged %q", out)
		}
	}
	if DroppedSentence("Pošli mi to akože do piatku, teda nie, do štvrtka, lebo to potrebujem skontrolovať.", "Pošli mi to do štvrtka, lebo to potrebujem skontrolovať.") {
		t.Error("a resolved correction is not a dropped sentence")
	}
}
