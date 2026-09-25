// Package disfluency removes non-lexical hesitation sounds (uh, um, ehm, hmm)
// from dictation before the model sees it.
//
// Only sounds that are never words are removed here; the choice is safe
// without understanding the sentence. Fillers that are also real words
// ("like", "I mean", "akože", "vlastne"), self-corrections and restarts depend
// on meaning and are left to the rewrite prompt. A small 4B model keeps these
// sounds about half the time and sometimes wraps them in commas ("Also, uh,
// redeploy"), so removing them here makes the result consistent and shortens
// the model input. The pass changes rewrite results, so a change to its rules
// needs a rewrite prompt version bump like a template change does.
package disfluency

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// hesitation matches the whole letter core of a token, case-insensitively.
// It deliberately excludes "eh", "em", "er", "ah", "oh", "mhm" and "uh-huh":
// those are words or answers in English or Slovak. "mm" is a hesitation
// except after a number, where it is millimetres.
var hesitation = regexp.MustCompile(`^(?i:u+h+|u+h*m+|e+hm+|e+m{2,}|e+h{2,}|e{3,}|e+r+m+|h+m+|m{2,})$`)
var millimetres = regexp.MustCompile(`^(?i:mm)$`)

// umWords lists languages where "um" is an ordinary word (German "um 3 Uhr").
var umWords = map[string]bool{"de": true}

type token struct {
	sep  string // whitespace before the word
	word string
}

// Strip returns text without hesitation sounds, with the surrounding commas,
// sentence punctuation and capitalization repaired. Text that consists of
// nothing but hesitation is returned unchanged.
func Strip(text string, languageHints []string) string {
	keepUm := false
	for _, hint := range languageHints {
		if umWords[strings.ToLower(hint)] {
			keepUm = true
		}
	}
	tokens := split(text)
	out := make([]token, 0, len(tokens))
	removed := false
	// pendingSep carries a newline from a removed word to the next kept word.
	pendingSep := ""
	capitalizeNext := false
	for i, t := range tokens {
		core, trailing, ok := hesitationCore(t.word)
		if ok && millimetres.MatchString(core) && len(out) > 0 && endsInDigit(out[len(out)-1].word) {
			ok = false
		}
		if !ok || (keepUm && strings.EqualFold(strings.Trim(core, "mM"), "u")) {
			if pendingSep != "" && !strings.Contains(t.sep, "\n") {
				t.sep = pendingSep
			}
			pendingSep = ""
			if capitalizeNext {
				t.word = capitalize(t.word)
				capitalizeNext = false
			}
			out = append(out, t)
			continue
		}
		removed = true
		if strings.Contains(t.sep, "\n") && len(out) > 0 {
			pendingSep = t.sep
		}
		atSentenceStart := len(out) == 0 || endsSentence(out[len(out)-1].word) || strings.Contains(t.sep, "\n")
		if atSentenceStart && startsUpper(core) {
			capitalizeNext = true
		}
		if len(out) == 0 {
			continue
		}
		prev := &out[len(out)-1]
		switch terminal := strings.TrimLeft(trailing, ","); {
		case terminal != "" && !endsSentence(prev.word):
			// "do it, uh." → "do it."
			prev.word = strings.TrimSuffix(prev.word, ",") + terminal
			capitalizeNext = false
		case i == len(tokens)-1 || nextIsSentenceEnd(tokens, i):
			// "do it, uh" at the end → "do it"
			prev.word = strings.TrimSuffix(prev.word, ",")
		}
	}
	if !removed || len(out) == 0 {
		return text
	}
	var b strings.Builder
	b.Grow(len(text))
	for i, t := range out {
		if i == 0 {
			t.sep = text[:len(text)-len(strings.TrimLeftFunc(text, unicode.IsSpace))]
		}
		b.WriteString(t.sep)
		b.WriteString(t.word)
	}
	b.WriteString(trailingSpace(text))
	return b.String()
}

// hesitationCore reports whether word is a hesitation sound with only
// trailing punctuation attached. Quoted, bracketed or code-like tokens are
// mentions of the word, not hesitation, and never match.
func hesitationCore(word string) (core, trailing string, ok bool) {
	end := len(word)
	for end > 0 {
		r, size := utf8.DecodeLastRuneInString(word[:end])
		if !strings.ContainsRune(",.!?…;:", r) {
			break
		}
		end -= size
	}
	core, trailing = word[:end], word[end:]
	if core == "" || strings.ContainsAny(trailing, ";:") || !hesitation.MatchString(core) {
		return "", "", false
	}
	// Acronyms such as "UM" or "HMM" are names, not sounds.
	if len(core) > 1 && core == strings.ToUpper(core) {
		return "", "", false
	}
	return core, trailing, true
}

func split(text string) []token {
	var tokens []token
	i := 0
	for i < len(text) {
		start := i
		for i < len(text) {
			r, size := utf8.DecodeRuneInString(text[i:])
			if !unicode.IsSpace(r) {
				break
			}
			i += size
		}
		wordStart := i
		for i < len(text) {
			r, size := utf8.DecodeRuneInString(text[i:])
			if unicode.IsSpace(r) {
				break
			}
			i += size
		}
		if wordStart == i {
			break // trailing whitespace; restored by trailingSpace
		}
		tokens = append(tokens, token{text[start:wordStart], text[wordStart:i]})
	}
	return tokens
}

func endsSentence(word string) bool {
	word = strings.TrimRight(word, `"'”’)]`)
	r, _ := utf8.DecodeLastRuneInString(word)
	return strings.ContainsRune(".!?…", r)
}

func endsInDigit(word string) bool {
	r, _ := utf8.DecodeLastRuneInString(word)
	return unicode.IsDigit(r)
}

func nextIsSentenceEnd(tokens []token, i int) bool {
	return i+1 < len(tokens) && strings.Contains(tokens[i+1].sep, "\n")
}

func startsUpper(s string) bool {
	r, _ := utf8.DecodeRuneInString(s)
	return unicode.IsUpper(r)
}

func trailingSpace(s string) string {
	return s[len(strings.TrimRightFunc(s, unicode.IsSpace)):]
}

// capitalize upper-cases the first letter of an all-lowercase word; words
// with inner capitals ("iPhone") are left as spoken.
func capitalize(word string) string {
	r, size := utf8.DecodeRuneInString(word)
	if !unicode.IsLower(r) {
		return word
	}
	rest := word[size:]
	if strings.IndexFunc(rest, unicode.IsUpper) >= 0 {
		return word
	}
	return string(unicode.ToUpper(r)) + rest
}
