// Package shield protects literal entities before inference. Detector changes
// require a version bump and updated corpus coverage tests.
package shield

import (
	"errors"
	"fmt"
	"net"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

const Version = 1

var ErrRestore = errors.New("shield_restore_failed")

type Match struct {
	Start, End   int
	Class, Value string
}
type Table []string
type detector struct {
	class   string
	pattern *regexp.Regexp
}

var detectors = []detector{
	{"url", regexp.MustCompile(`https?://[^\s<>"⟦⟧]+`)},
	{"email", regexp.MustCompile(`[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}`)},
	{"path", regexp.MustCompile(`(?:[A-Za-z]:\\|~/|/)[^\s<>"⟦⟧]+`)},
	{"ip", regexp.MustCompile(`(?:[0-9]{1,3}\.){3}[0-9]{1,3}|[0-9A-Fa-f]*:[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*`)},
	{"version", regexp.MustCompile(`v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.\-]+)?`)},
	{"currency", regexp.MustCompile(`(?:[$€£]|USD\s+|EUR\s+|GBP\s+)[0-9]+(?:[.,][0-9]+)?|[0-9]+(?:[.,][0-9]+)?\s+(?:EUR|USD|GBP)`)},
	{"date", regexp.MustCompile(`(?i)[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}[./][0-9]{1,2}[./][0-9]{4}|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|January|February|March|April|May|June|July|August|September|October|November|December|pondelok|utorok|streda|štvrtok|piatok|sobota|nedeľa|január|február|marec|apríl|máj|jún|júl|august|september|október|november|december`)},
	{"time", regexp.MustCompile(`(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9])?`)},
	{"number", regexp.MustCompile(`[+-]?[0-9]+(?:[.,][0-9]+)*%?`)},
}

func word(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' }
func boundaries(text string, start, end int) bool {
	if start > 0 {
		r, _ := utf8.DecodeLastRuneInString(text[:start])
		if word(r) {
			return false
		}
	}
	if end < len(text) {
		r, _ := utf8.DecodeRuneInString(text[end:])
		if word(r) {
			return false
		}
	}
	return true
}

// Detect resolves overlapping matches by earliest position, then longest span.
func Detect(text string) []Match {
	var matches []Match
	for _, d := range detectors {
		for _, p := range d.pattern.FindAllStringIndex(text, -1) {
			start, end := p[0], p[1]
			if d.class == "url" || d.class == "path" {
				end = start + len(strings.TrimRight(text[start:end], ".,;!?)"))
			}
			if !boundaries(text, start, end) {
				continue
			}
			value := text[start:end]
			if d.class == "ip" && net.ParseIP(value) == nil {
				continue
			}
			matches = append(matches, Match{start, end, d.class, value})
		}
	}
	sort.SliceStable(matches, func(i, j int) bool {
		if matches[i].Start == matches[j].Start {
			return matches[i].End > matches[j].End
		}
		return matches[i].Start < matches[j].Start
	})
	selected := make([]Match, 0, len(matches))
	end := 0
	for _, m := range matches {
		if m.Start >= end {
			selected = append(selected, m)
			end = m.End
		}
	}
	return selected
}
func Shield(text string) (string, Table) {
	matches := Detect(text)
	table := make(Table, 0, len(matches))
	var out strings.Builder
	start := 0
	for _, m := range matches {
		out.WriteString(text[start:m.Start])
		fmt.Fprintf(&out, "⟦E%d⟧", len(table))
		table = append(table, m.Value)
		start = m.End
	}
	out.WriteString(text[start:])
	return out.String(), table
}

var placeholder = regexp.MustCompile(`⟦E[0-9]+⟧`)

func Restore(output string, table Table) (string, error) {
	replacements := make(map[string]string, len(table))
	seen := make(map[string]bool, len(table))
	for i, v := range table {
		replacements[fmt.Sprintf("⟦E%d⟧", i)] = v
	}
	valid := true
	// Validate before substitution so source values can never become placeholders.
	for _, token := range placeholder.FindAllString(output, -1) {
		if _, ok := replacements[token]; !ok || seen[token] {
			valid = false
		}
		seen[token] = true
	}
	remainder := placeholder.ReplaceAllString(output, "")
	if !valid || len(seen) != len(table) || strings.ContainsAny(remainder, "⟦⟧") {
		return "", ErrRestore
	}
	restored := placeholder.ReplaceAllStringFunc(output, func(token string) string { return replacements[token] })
	if strings.ContainsAny(restored, "⟦⟧") {
		return "", ErrRestore
	}
	return restored, nil
}
