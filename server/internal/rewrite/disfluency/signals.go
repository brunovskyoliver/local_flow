package disfluency

import (
	"regexp"
	"strings"
	"unicode"
)

// Every prompt byte costs prefill time on each dictation (about 0.3 ms per
// character on the reference 4B model), so the rewrite adds the spoken-speech
// rules only when the dictation shows signs of needing them. A false positive
// costs latency, never quality.

// cues are fillers and correction markers the spoken rules act on, in the
// languages the rules cover. Matching is by whole word, case-insensitive.
var cues = regexp.MustCompile(`(?i)(?:^|[^\p{L}])(like|you know|i mean|basically|sorry|wait|actually|or rather|akože|proste|vlastne|v podstate|ako keby|vieš|hej|teda|respektíve|prepáč|alebo skôr|pardon)(?:[^\p{L}]|$)|, no,`)

// Signals reports whether text reads like unedited speech: it contains a
// hesitation sound, a filler or correction cue, a word repeated within three
// words ("the the", "why were why are", "I want to I need") or a cut-off word
// before its full form ("displa display").
func Signals(text string) bool {
	if cues.MatchString(text) {
		return true
	}
	words := letterWords(text)
	for i, w := range words {
		if hesitation.MatchString(w) {
			return true
		}
		for d := 1; d <= 3 && i+d < len(words); d++ {
			if strings.EqualFold(w, words[i+d]) {
				return true
			}
		}
		if i+1 < len(words) {
			next := strings.ToLower(words[i+1])
			lw := strings.ToLower(w)
			// "a" and "i" are words that often start the next one.
			if lw != "a" && lw != "i" && len(lw) < len(next) && strings.HasPrefix(next, lw) {
				return true
			}
		}
	}
	return false
}

// letterWords splits text into runs of letters and apostrophes; numbers and
// symbols separate words and are never compared.
func letterWords(text string) []string {
	return strings.FieldsFunc(text, func(r rune) bool { return !unicode.IsLetter(r) && r != '\'' && r != '’' })
}
