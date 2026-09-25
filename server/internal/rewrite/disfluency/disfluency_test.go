package disfluency

import "testing"

func TestStrip(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		// Real dictations the 4B model left unchanged or comma-wrapped.
		{"Also uh redeploy the app, please.", "Also redeploy the app, please."},
		{"Also remove the copy and retranscribe um buttons.", "Also remove the copy and retranscribe buttons."},
		{"Uh I've got these findings. Uh please uh fix some of them.", "I've got these findings. Please fix some of them."},
		{"platform for uh, sub-GUI apps, uh, to do testing", "platform for sub-GUI apps, to do testing"},
		{"Okay, uh this is still not working.", "Okay, this is still not working."},
		{"Hmm, this seems weird.", "This seems weird."},
		{"Ehm, záleží, že čo robím.", "Záleží, že čo robím."},
		{"Že vyslovene, ehm, ísť teraz tým konceptom.", "Že vyslovene, ísť teraz tým konceptom."},
		// Sentence punctuation moves to the kept word.
		{"Please do it, uh.", "Please do it."},
		{"Is that right uh?", "Is that right?"},
		{"Please do it, uh", "Please do it"},
		{"First line\nuh second line", "First line\nsecond line"},
		{"Umm. Uhh, okay.", "Okay."},
		{"  uh indented", "  indented"},
		{"trailing uh \n", "trailing \n"},
		{"Uhm iPhone works.", "iPhone works."},
		// Words, units, answers, acronyms and mentions stay.
		{"Mhm, sounds good.", "Mhm, sounds good."},
		{"Eh, whatever you think.", "Eh, whatever you think."},
		{"Get 'em by 5 mm.", "Get 'em by 5 mm."},
		{"Try to find the problem. Mm.", "Try to find the problem."},
		{"Mm, not sure about that.", "Not sure about that."},
		{"She studied at UM and HMM.", "She studied at UM and HMM."},
		{`Never type "um" in the docs.`, `Never type "um" in the docs.`},
		{"The ratio uh: 3.", "The ratio uh: 3."},
		{"Hmm", "Hmm"},
		{"No hesitation here.", "No hesitation here."},
		{"", ""},
	} {
		if got := Strip(tc.in, nil); got != tc.want {
			t.Errorf("Strip(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestStripKeepsGermanUm(t *testing.T) {
	in := "Treffen um 3 Uhr, ähm, uh, im Büro."
	if got := Strip(in, []string{"de"}); got != "Treffen um 3 Uhr, ähm, im Büro." {
		t.Fatalf("got %q", got)
	}
	if got := Strip("Uh meet um three.", []string{"en"}); got != "Meet three." {
		t.Fatalf("got %q", got)
	}
}
