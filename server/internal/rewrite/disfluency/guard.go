package disfluency

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// markers introduce a spoken self-correction: "to Peter, sorry, to Martin".
// A bare "no" counts only between commas, where it cannot be an answer or a
// negation.
var markers = regexp.MustCompile(`(?i)(?:^|[^\p{L}])(sorry|i mean|no wait|wait|or rather|teda nie|vlastne nie|prepáč|respektíve|alebo skôr|pardon)(?:[^\p{L}]|$)|,\s*(no),`)

// HalfCorrected reports whether the model dropped a correction marker but kept
// the words it corrected. "Send it to Peter, sorry, to Martin" must become "to
// Martin" or stay as spoken; "to Peter, to Martin" states the abandoned name as
// fact, so the rewrite is rejected. Value corrections (numbers, dates, URLs)
// are also checked by the entity shield.
func HalfCorrected(input, output string) bool {
	for _, loc := range markers.FindAllStringSubmatchIndex(input, -1) {
		start, end := loc[2], loc[3]
		if start < 0 {
			start, end = loc[4], loc[5]
		}
		marker := strings.ToLower(input[start:end])
		replaced, ok := wordBefore(input[:start])
		if !ok || countWord(output, marker) >= countWord(input, marker) {
			continue
		}
		if countWord(output, replaced) >= countWord(input, replaced) {
			return true
		}
	}
	return false
}

// wordBefore returns the last word before a marker in the same sentence: the
// end of the phrase the marker corrects.
func wordBefore(prefix string) (string, bool) {
	end := len(prefix)
	for end > 0 {
		r, size := utf8.DecodeLastRuneInString(prefix[:end])
		if strings.ContainsRune(".!?…\n", r) {
			return "", false
		}
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			break
		}
		end -= size
	}
	start := end
	for start > 0 {
		r, size := utf8.DecodeLastRuneInString(prefix[:start])
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) {
			break
		}
		start -= size
	}
	if start == end {
		return "", false
	}
	return strings.ToLower(prefix[start:end]), true
}

// countWord counts whole-word, case-insensitive occurrences of a word or
// phrase.
func countWord(text, word string) int {
	text = strings.ToLower(text)
	n := 0
	for i := 0; ; {
		j := strings.Index(text[i:], word)
		if j < 0 {
			return n
		}
		start, end := i+j, i+j+len(word)
		before, _ := utf8.DecodeLastRuneInString(text[:start])
		after, _ := utf8.DecodeRuneInString(text[end:])
		if (start == 0 || !isWordRune(before)) && (end == len(text) || !isWordRune(after)) {
			n++
		}
		i = end
	}
}

func isWordRune(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }

// DroppedSentence reports whether the output lost a whole input sentence: one
// with at least four distinct words of which fewer than a third survive.
// Filler-only sentences ("Yeah.", "Okay.") are too short to count. Words are
// compared by their first five letters, so a grammar fix to a word ending
// (Slovak inflection, "try" → "tried") still counts as present.
func DroppedSentence(input, output string) bool {
	present := map[string]bool{}
	for _, w := range letterWords(output) {
		present[stem(w)] = true
	}
	for _, sentence := range sentences(input) {
		words := map[string]bool{}
		for _, w := range letterWords(sentence) {
			if utf8.RuneCountInString(w) >= 3 {
				words[stem(w)] = true
			}
		}
		if len(words) < 4 {
			continue
		}
		kept := 0
		for w := range words {
			if present[w] {
				kept++
			}
		}
		if 3*kept < len(words) {
			return true
		}
	}
	return false
}

func sentences(text string) []string {
	var out []string
	start := 0
	for i, r := range text {
		if strings.ContainsRune(".!?…\n", r) {
			out = append(out, text[start:i])
			start = i + utf8.RuneLen(r)
		}
	}
	return append(out, text[start:])
}

func stem(word string) string {
	word = strings.ToLower(word)
	if utf8.RuneCountInString(word) <= 5 {
		return word
	}
	return string([]rune(word)[:5])
}
