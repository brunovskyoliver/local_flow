// Package shield protects literal entities before inference. Detector changes
// require a version bump and updated corpus coverage tests.
//
// Long literals that a model tends to mangle and a speaker rarely corrects
// (URLs, emails, paths, IPs, versions) are replaced by ⟦E<n>⟧ placeholders.
// Numbers, dates, times and amounts stay visible, because a model can only
// resolve "30, no, 60" when it can read the values; Restore checks them
// afterwards instead.
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

// Version 2 leaves numbers, dates, times and amounts visible and lets a spoken
// self-correction drop the value it replaces; see Restore.
const Version = 2

// correctionGap bounds, in input bytes, how far a correcting value may follow
// the value it replaces ("30 seconds, wait, make it 60").
const correctionGap = 64

var ErrRestore = errors.New("shield_restore_failed")

type Match struct {
	Start, End   int
	Class, Value string
}

// Entry is one protected value and where it stood in the input.
type Entry struct {
	Class, Value string
	Start, End   int
}

// Table records the protected values of one input.
type Table struct {
	Shielded []Entry // replaced by ⟦E<n>⟧, in order
	Checked  []Entry // left visible, checked in the output
}

// visible classes are left in the text and checked after generation.
var visible = map[string]bool{"number": true, "date": true, "time": true, "currency": true}

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
	{"date", regexp.MustCompile(`(?i)[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}[./][0-9]{1,2}[./][0-9]{4}|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|January|February|March|April|May|June|July|August|September|October|November|December|pondel(?:ok|ka|ku|kom|ky|kov)|utor(?:ok|ka|ku|kom|ky|kov)|stred(?:a|y|e|u|ou|ách|ami)|štvrt(?:ok|ka|ku|kom|ky|kov)|piat(?:ok|ka|ku|kom|ky|kov)|sobot(?:a|y|e|u|ou|ách|ami)|nede(?:ľa|le|ľu|ľou|ľ|ľách|ľami)|januá?r(?:a|om)?|februá?r(?:a|om)?|mar(?:ec|ca|ci|com)|aprí?l(?:a|i|om)?|má(?:j|ja|ji|jom)|jú(?:n|na|ni|nom)|jú(?:l|la|li|lom)|august(?:a|e|om)?|septem(?:ber|bra|bri|brom)|októ(?:ber|bra|bri|brom)|novem(?:ber|bra|bri|brom)|decem(?:ber|bra|bri|brom)`)},
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
	var table Table
	var out strings.Builder
	start := 0
	for _, m := range Detect(text) {
		e := Entry{m.Class, m.Value, m.Start, m.End}
		if visible[m.Class] {
			table.Checked = append(table.Checked, e)
			continue
		}
		out.WriteString(text[start:m.Start])
		fmt.Fprintf(&out, "⟦E%d⟧", len(table.Shielded))
		table.Shielded = append(table.Shielded, e)
		start = m.End
	}
	out.WriteString(text[start:])
	return out.String(), table
}

var placeholder = regexp.MustCompile(`⟦E[0-9]+⟧`)

// Restore replaces placeholders with their values and reports how many it
// restored. No placeholder may repeat or be invented, and no visible value may
// be changed. A value may be missing only when the speaker corrected it: a
// later value of the same class, close behind it in the input, survives
// ("Tuesday, no, Wednesday", "30, sorry, 60"). A lone value, or the last of a
// run, must always survive.
func Restore(output string, table Table) (string, int, error) {
	index := make(map[string]int, len(table.Shielded))
	for i := range table.Shielded {
		index[fmt.Sprintf("⟦E%d⟧", i)] = i
	}
	present := make([]bool, len(table.Shielded))
	restoredCount := 0
	valid := true
	// Validate before substitution so source values can never become placeholders.
	for _, token := range placeholder.FindAllString(output, -1) {
		i, ok := index[token]
		if !ok || present[i] {
			valid = false
			continue
		}
		present[i] = true
		restoredCount++
	}
	remainder := placeholder.ReplaceAllString(output, "")
	if !valid || !covered(table.Shielded, present) || strings.ContainsAny(remainder, "⟦⟧") {
		return "", 0, ErrRestore
	}
	if !covered(table.Checked, survivors(table.Checked, output)) {
		return "", 0, ErrRestore
	}
	restored := placeholder.ReplaceAllStringFunc(output, func(token string) string { return table.Shielded[index[token]].Value })
	if strings.ContainsAny(restored, "⟦⟧") {
		return "", 0, ErrRestore
	}
	return restored, restoredCount, nil
}

// survivors marks which visible input values still appear in the output. When
// a value occurs k times in the output, its last k occurrences in the input
// count as present, since a correction abandons the earlier ones.
func survivors(entries []Entry, output string) []bool {
	counts := map[string]int{}
	for _, m := range Detect(output) {
		if visible[m.Class] {
			counts[strings.ToLower(m.Value)]++
		}
	}
	present := make([]bool, len(entries))
	for i := len(entries) - 1; i >= 0; i-- {
		key := strings.ToLower(entries[i].Value)
		if counts[key] > 0 {
			counts[key]--
			present[i] = true
		}
	}
	return present
}

// covered reports whether every entry is present or superseded by a nearby
// later entry of the same class that is itself covered.
func covered(entries []Entry, present []bool) bool {
	ok := make([]bool, len(entries))
	for i := len(entries) - 1; i >= 0; i-- {
		if present[i] {
			ok[i] = true
			continue
		}
		for j := i + 1; j < len(entries) && entries[j].Start-entries[i].End <= correctionGap; j++ {
			if entries[j].Class == entries[i].Class {
				ok[i] = ok[j]
				break
			}
		}
		if !ok[i] {
			return false
		}
	}
	return true
}
