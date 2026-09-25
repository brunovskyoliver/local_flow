package analysis

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"localflow/server/internal/analysis/prompts"
	"localflow/server/internal/backend"
)

// The analysis pipeline (ADR 0022). The model only writes markdown notes
// under fixed headings and picks list numbers; this code parses the notes,
// attaches sources, checks deadlines against the transcript, maps owners to
// participants and builds the result object the protocol validates.
//
//	chunk:     notes per part → partial result
//	synthesis: partials → merged overview + topics, reviewed item lists
//	full:      chunk then synthesis, inside one request
//
// Every step degrades instead of failing the request: a part the server
// refuses for size is split in half, unreadable notes count as discussion,
// a failed merge falls back to the parts' own summaries and a failed review
// keeps the deduplicated list.

// call is one backend completion; the handler binds deadlines and progress.
type call func(ctx context.Context, system, user string, maxTokens int, temperature float64) (string, error)

// optionalReserve is the request time a nice-to-have call (a retry, a
// review) must leave; below it the step is skipped and its fallback used.
const optionalReserve = 45 * time.Second

// Output token caps per step.
const (
	reviewTokens = 200
	retryTemp    = 0.3
)

// Final list caps after review; a partial keeps the protocol's partial caps.
var reviewCaps = map[string]int{
	"decisions": 20, "action_items": 30, "open_questions": 15, "risks": 15,
}

var reviewWords = map[string][2]string{
	"decisions":      {"decisions", "real decisions: something was agreed or chosen"},
	"action_items":   {"action items", "real commitments: someone agreed to do something or was given a task"},
	"open_questions": {"open questions", "questions the meeting left open"},
	"risks":          {"risks", "concrete risks or concerns"},
}

type pipeline struct {
	req      *Request
	call     call
	limits   Limits
	deadline time.Time
	// rejected collects content-free reasons for the log line.
	rejected []string
	labels   map[string]string // speaker_id → name the model sees
	tokens   map[string][]string
}

func newPipeline(req *Request, c call, limits Limits, deadline time.Time) *pipeline {
	p := &pipeline{req: req, call: c, limits: limits, deadline: deadline,
		labels: map[string]string{}, tokens: map[string][]string{}}
	for i, participant := range req.Participants {
		if participant.Name != nil {
			p.labels[participant.SpeakerID] = *participant.Name
		} else {
			p.labels[participant.SpeakerID] = "Speaker " + strconv.Itoa(i+1)
		}
	}
	return p
}

func (p *pipeline) note(reason string) { p.rejected = append(p.rejected, reason) }

func (p *pipeline) timeLeft() time.Duration { return time.Until(p.deadline) }

// run produces the stage's result; the caller still validates it.
func (p *pipeline) run(ctx context.Context) (*Analysis, error) {
	var result *Analysis
	var err error
	switch p.req.Stage {
	case StageChunk:
		result, err = p.partial(ctx, p.req.Segments)
	case StageFull:
		var part *Analysis
		if part, err = p.partial(ctx, p.req.Segments); err == nil {
			result, err = p.synthesize(ctx, []Analysis{*part})
		}
	default:
		result, err = p.synthesize(ctx, p.req.Partials)
	}
	if err != nil {
		return nil, err
	}
	result.SchemaVersion = SchemaVersion
	result.MeetingID = p.req.Meeting.ID
	result.Language = p.req.Meeting.LanguagePolicy.Output
	result.Partial = p.req.Stage == StageChunk
	result.Summary.WholeMeeting = !result.Partial
	if result.NextSteps == nil {
		result.NextSteps = []Item{}
	}
	return result, nil
}

// ask runs one prompt; an answer that fails `usable` or comes back in the
// wrong language is asked once more when time allows. A backend failure of
// the retry keeps the first answer unless the request itself is over.
func (p *pipeline) ask(ctx context.Context, system, user string, maxTokens int, usable func(string) bool) (string, error) {
	first, err := p.call(ctx, system, user, maxTokens, 0)
	if err != nil {
		return "", err
	}
	first = stripThinking(first)
	ok, langOK := usable(first), p.languageOK(first)
	if ok && langOK {
		return first, nil
	}
	if !ok {
		p.note("format")
	} else {
		p.note("language")
	}
	if p.timeLeft() < optionalReserve {
		return first, nil
	}
	second, err := p.call(ctx, system, user+"\n\n"+prompts.LanguageReminder(p.req.Meeting.LanguagePolicy.Output), maxTokens, retryTemp)
	if err != nil {
		if ctx.Err() != nil || errors.Is(err, ErrPreempted) {
			return "", err
		}
		return first, nil
	}
	second = stripThinking(second)
	if usable(second) || !ok {
		return second, nil
	}
	return first, nil
}

// --- chunk: notes per part ---

type partNotes struct {
	segments []Segment
	sections map[string][]string
}

// notes asks for the notes of one part; a part the server refuses for size
// is split in half until a single segment remains.
func (p *pipeline) notes(ctx context.Context, segments []Segment) ([]partNotes, error) {
	out, err := p.ask(ctx, prompts.Notes(p.req.Meeting.LanguagePolicy.Output).Text,
		p.transcript(segments), p.limits.OutputTokensChunk, hasNoteHeadings)
	if errors.Is(err, backend.ErrTooLarge) && len(segments) > 1 {
		p.note("too_large_split")
		half := len(segments) / 2
		first, err := p.notes(ctx, segments[:half])
		if err != nil {
			return nil, err
		}
		second, err := p.notes(ctx, segments[half:])
		if err != nil {
			return nil, err
		}
		return append(first, second...), nil
	}
	if err != nil {
		return nil, err
	}
	sections := parseSections(out)
	if !hasNoteHeadings(out) {
		// Prose without the headings is still a summary of the part.
		sections = map[string][]string{prompts.HeadingDiscussed: bulletLines(out)}
	}
	return []partNotes{{segments, sections}}, nil
}

func (p *pipeline) transcript(segments []Segment) string {
	var b strings.Builder
	if p.req.Meeting.Title != "" {
		b.WriteString("Meeting: " + p.req.Meeting.Title + "\n\n")
	}
	for _, s := range segments {
		if s.SpeakerID != nil {
			b.WriteString(p.labels[*s.SpeakerID] + ": ")
		}
		b.WriteString(s.Text)
		b.WriteString("\n")
	}
	return b.String()
}

// partial builds a chunk result from the notes: the discussion becomes the
// summary synthesis reads, every item gets the segments it rests on.
func (p *pipeline) partial(ctx context.Context, segments []Segment) (*Analysis, error) {
	parts, err := p.notes(ctx, segments)
	if err != nil {
		return nil, err
	}
	a := &Analysis{Topics: []Topic{}, Decisions: []Item{}, ActionItems: []ActionItem{},
		NextSteps: []Item{}, OpenQuestions: []Item{}, Risks: []Item{}}
	var discussed []string
	dropped := 0
	for _, part := range parts {
		discussed = append(discussed, part.sections[prompts.HeadingDiscussed]...)
		for _, list := range []struct {
			heading string
			into    *[]Item
		}{
			{prompts.HeadingDecisions, &a.Decisions},
			{prompts.HeadingOpenQuestions, &a.OpenQuestions},
			{prompts.HeadingRisks, &a.Risks},
		} {
			for _, text := range part.sections[list.heading] {
				sources := p.pickSources(text, part.segments)
				if len(sources) == 0 {
					dropped++
					continue
				}
				*list.into = append(*list.into, Item{Text: bound(text, MaxItemText), Sources: sources})
			}
		}
		for _, line := range part.sections[prompts.HeadingCommitments] {
			item, ok := p.action(line, part.segments)
			if !ok {
				dropped++
				continue
			}
			a.ActionItems = append(a.ActionItems, item)
		}
	}
	if dropped > 0 {
		p.note("ungrounded_" + strconv.Itoa(dropped))
	}
	a.Summary = Summary{Text: joinBounded(discussed, MaxSummaryBytes), Sources: []SourceRef{}}
	if a.Summary.Text == "" {
		return nil, &RequestError{CodeOutputInvalid, "notes carry no discussion"}
	}
	a.Decisions = dedupeItems(a.Decisions)
	a.OpenQuestions = dedupeItems(a.OpenQuestions)
	a.Risks = dedupeItems(a.Risks)
	a.ActionItems = dedupeActions(a.ActionItems, p.ownerLabel)
	return a, nil
}

var dueMarker = regexp.MustCompile(`(?i)\s*\(\s*(?:due|deadline|term[ií]n|do|until|by)\s*:\s*([^()]{1,80})\)\s*\.?\s*$`)
var ownerPrefix = regexp.MustCompile(`^\**([^:*]{1,60}?)\**\s*:\s+(.+)$`)

// action reads "who: what (due: when)". The deadline counts only when its
// words were said in the part; the owner maps to a participant when the
// name matches one.
func (p *pipeline) action(line string, segments []Segment) (ActionItem, bool) {
	text, who, phrase := line, "", ""
	if m := dueMarker.FindStringSubmatchIndex(text); m != nil {
		phrase = strings.TrimSpace(text[m[2]:m[3]])
		text = strings.TrimRight(text[:m[0]], " .")
	}
	if m := ownerPrefix.FindStringSubmatch(text); m != nil && len(strings.Fields(m[1])) <= 4 {
		who, text = strings.TrimSpace(m[1]), strings.TrimSpace(m[2])
	}
	if text == "" {
		return ActionItem{}, false
	}
	sources := p.pickSources(text, segments)
	if len(sources) == 0 {
		return ActionItem{}, false
	}
	item := ActionItem{Text: bound(text, MaxItemText), Due: Due{State: "absent"}, Sources: sources}
	item.Owner, item.OwnershipState = p.owner(who)
	if phrase != "" && !isEmptyEntry(phrase) {
		if source, ok := p.saidIn(phrase, segments); ok {
			original := bound(phrase, MaxDueOriginal)
			item.Due = Due{State: "unresolved", Original: &original, Source: &source}
		} else {
			p.note("due_not_said")
		}
	}
	return item, true
}

func (p *pipeline) owner(who string) (Owner, string) {
	name := fold(who)
	if name == "" || isEmptyEntry(who) {
		return Owner{Kind: "none"}, "unresolved"
	}
	var firstName []string
	for _, participant := range p.req.Participants {
		label := fold(p.labels[participant.SpeakerID])
		id := participant.SpeakerID
		if label == name {
			return Owner{Kind: "participant", SpeakerID: &id}, "explicit"
		}
		if participant.Name != nil && firstWord(label) == firstWord(name) {
			firstName = append(firstName, id)
		}
	}
	if len(firstName) == 1 {
		return Owner{Kind: "participant", SpeakerID: &firstName[0]}, "explicit"
	}
	mentioned := bound(who, MaxNameBytes)
	return Owner{Kind: "mentioned", Name: &mentioned}, "supported"
}

func firstWord(s string) string {
	if f := strings.Fields(s); len(f) > 0 {
		return f[0]
	}
	return ""
}

func (p *pipeline) ownerLabel(item ActionItem) string {
	switch item.Owner.Kind {
	case "participant":
		return p.labels[*item.Owner.SpeakerID]
	case "mentioned":
		return *item.Owner.Name
	}
	return ""
}

// --- synthesis: merge and review ---

func (p *pipeline) synthesize(ctx context.Context, partials []Analysis) (*Analysis, error) {
	a := &Analysis{NextSteps: []Item{}}
	for _, part := range partials {
		a.Decisions = append(a.Decisions, part.Decisions...)
		a.ActionItems = append(a.ActionItems, part.ActionItems...)
		a.OpenQuestions = append(a.OpenQuestions, part.OpenQuestions...)
		a.Risks = append(a.Risks, part.Risks...)
	}
	a.Decisions = dedupeItems(a.Decisions)
	a.ActionItems = dedupeActions(a.ActionItems, p.ownerLabel)
	a.OpenQuestions = dedupeItems(a.OpenQuestions)
	a.Risks = dedupeItems(a.Risks)

	blocks := make([]string, 0, len(partials)+1)
	for i, part := range partials {
		blocks = append(blocks, fmt.Sprintf("## Part %d\n%s", i+1, partText(part)))
	}
	if len(p.req.Notes) > 0 {
		var b strings.Builder
		b.WriteString("## Notes written during the meeting\n")
		for _, n := range p.req.Notes {
			b.WriteString(n.Text + "\n")
		}
		blocks = append(blocks, b.String())
	}
	merged, err := p.merge(ctx, blocks)
	if err != nil {
		if ctx.Err() != nil || errors.Is(err, ErrPreempted) {
			return nil, err
		}
		p.note("merge_failed")
	}
	overview, topics := parseOverview(merged)
	if overview == "" {
		// The parts' own summaries stand in for a merge that failed.
		p.note("merge_fallback")
		var lines []string
		for _, part := range partials {
			lines = append(lines, strings.Split(part.Summary.Text, "\n")...)
		}
		overview = joinBounded(lines, MaxSummaryBytes)
	}
	a.Summary = Summary{Text: overview, Sources: []SourceRef{}}
	a.Topics = topics

	lists := []struct {
		name   string
		render func(i int) string
		keep   func(order []int)
		count  int
	}{
		{"decisions", func(i int) string { return a.Decisions[i].Text }, func(o []int) { a.Decisions = pick(a.Decisions, o) }, len(a.Decisions)},
		{"action_items", func(i int) string {
			if owner := p.ownerLabel(a.ActionItems[i]); owner != "" {
				return owner + ": " + a.ActionItems[i].Text
			}
			return a.ActionItems[i].Text
		}, func(o []int) { a.ActionItems = pick(a.ActionItems, o) }, len(a.ActionItems)},
		{"open_questions", func(i int) string { return a.OpenQuestions[i].Text }, func(o []int) { a.OpenQuestions = pick(a.OpenQuestions, o) }, len(a.OpenQuestions)},
		{"risks", func(i int) string { return a.Risks[i].Text }, func(o []int) { a.Risks = pick(a.Risks, o) }, len(a.Risks)},
	}
	for _, list := range lists {
		order, err := p.review(ctx, list.name, list.count, list.render)
		if err != nil {
			return nil, err
		}
		list.keep(order)
	}
	return a, nil
}

// merge writes the overview and topics; input the server refuses for size is
// merged in halves first.
func (p *pipeline) merge(ctx context.Context, blocks []string) (string, error) {
	// The overview is judged on its own: Slovak topics under an English
	// overview pass a whole-answer language check.
	usable := func(md string) bool {
		overview, _ := parseOverview(md)
		return overview != "" && p.languageOK(overview)
	}
	out, err := p.ask(ctx, prompts.Merge(p.req.Meeting.LanguagePolicy.Output).Text,
		strings.Join(blocks, "\n\n"), p.limits.OutputTokensFull, usable)
	if errors.Is(err, backend.ErrTooLarge) && len(blocks) > 1 {
		p.note("too_large_split")
		half := (len(blocks) + 1) / 2
		first, err := p.merge(ctx, blocks[:half])
		if err != nil {
			return "", err
		}
		second, err := p.merge(ctx, blocks[half:])
		if err != nil {
			return "", err
		}
		return p.merge(ctx, []string{first, second})
	}
	return out, err
}

// review returns the indexes to keep, most important first. Short lists,
// a late request, an unreadable answer or a failed call keep the list as
// it is, capped.
func (p *pipeline) review(ctx context.Context, name string, count int, render func(int) string) ([]int, error) {
	limit := reviewCaps[name]
	all := make([]int, 0, count)
	for i := 0; i < count && i < limit; i++ {
		all = append(all, i)
	}
	if count <= 3 || p.timeLeft() < optionalReserve {
		return all, nil
	}
	var b strings.Builder
	for i := 0; i < count; i++ {
		fmt.Fprintf(&b, "%d. %s\n", i+1, render(i))
	}
	words := reviewWords[name]
	out, err := p.call(ctx, prompts.Review(words[0], words[1], limit).Text, b.String(), reviewTokens, 0)
	if err != nil {
		if ctx.Err() != nil || errors.Is(err, ErrPreempted) {
			return nil, err
		}
		p.note("review_failed")
		return all, nil
	}
	var picked []int
	seen := map[int]bool{}
	for _, n := range number.FindAllString(stripThinking(out), -1) {
		i, _ := strconv.Atoi(n)
		if i >= 1 && i <= count && !seen[i-1] && len(picked) < limit {
			seen[i-1] = true
			picked = append(picked, i-1)
		}
	}
	if len(picked) == 0 {
		p.note("review_unreadable")
		return all, nil
	}
	return picked, nil
}

var number = regexp.MustCompile(`\d+`)

func pick[T any](items []T, order []int) []T {
	out := make([]T, 0, len(order))
	for _, i := range order {
		out = append(out, items[i])
	}
	return out
}

// partText is a partial as the merge reads it: its summary and topics.
func partText(a Analysis) string {
	var b strings.Builder
	b.WriteString(a.Summary.Text + "\n")
	for _, t := range a.Topics {
		b.WriteString("### " + t.Title + "\n")
		for _, bullet := range t.Bullets {
			b.WriteString("- " + bullet + "\n")
		}
	}
	return b.String()
}

// --- markdown ---

// headingTable maps folded heading prefixes, including the translations a
// model writes despite the prompt, to the canonical headings.
var headingTable = []struct{ prefix, heading string }{
	{"discuss", prompts.HeadingDiscussed}, {"prediskut", prompts.HeadingDiscussed},
	{"diskut", prompts.HeadingDiscussed}, {"prebra", prompts.HeadingDiscussed},
	{"probr", prompts.HeadingDiscussed},
	{"decision", prompts.HeadingDecisions}, {"rozhodnut", prompts.HeadingDecisions},
	{"commitment", prompts.HeadingCommitments}, {"action", prompts.HeadingCommitments},
	{"zavazk", prompts.HeadingCommitments}, {"ulohy", prompts.HeadingCommitments},
	{"ukoly", prompts.HeadingCommitments},
	{"open question", prompts.HeadingOpenQuestions}, {"otvoren", prompts.HeadingOpenQuestions},
	{"otevren", prompts.HeadingOpenQuestions}, {"otazk", prompts.HeadingOpenQuestions},
	{"risk", prompts.HeadingRisks}, {"rizik", prompts.HeadingRisks},
	{"overview", prompts.HeadingOverview}, {"prehlad", prompts.HeadingOverview},
	{"prehled", prompts.HeadingOverview}, {"zhrnut", prompts.HeadingOverview},
	{"shrnut", prompts.HeadingOverview}, {"summary", prompts.HeadingOverview},
	{"topic", prompts.HeadingTopics}, {"tem", prompts.HeadingTopics},
}

var headingLine = regexp.MustCompile(`^(#{1,6})\s*(.+?)\s*#*$`)
var boldLine = regexp.MustCompile(`^\*\*(.+?)\*\*:?$`)
var bulletPrefix = regexp.MustCompile(`^(?:[-*•+]|\d+[.)])\s+`)

func canonicalHeading(title string) string {
	folded := fold(strings.Trim(title, " :*"))
	for _, h := range headingTable {
		if strings.HasPrefix(folded, h.prefix) {
			return h.heading
		}
	}
	return ""
}

// heading reports a heading line: its level (bold lines count as level 2)
// and title.
func heading(line string) (int, string, bool) {
	if m := headingLine.FindStringSubmatch(line); m != nil {
		return len(m[1]), strings.TrimSpace(m[2]), true
	}
	if m := boldLine.FindStringSubmatch(line); m != nil {
		return 2, strings.TrimSpace(m[1]), true
	}
	return 0, "", false
}

// parseSections collects the entries under each known heading; an entry is
// a bullet or a plain line, with markdown emphasis and "none" lines dropped.
func parseSections(md string) map[string][]string {
	out := map[string][]string{}
	current := ""
	for _, raw := range strings.Split(md, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if _, title, ok := heading(line); ok {
			current = canonicalHeading(title)
			continue
		}
		if current == "" {
			continue
		}
		if entry := cleanEntry(line); entry != "" {
			out[current] = append(out[current], entry)
		}
	}
	return out
}

func hasNoteHeadings(md string) bool {
	for _, raw := range strings.Split(md, "\n") {
		if _, title, ok := heading(strings.TrimSpace(raw)); ok {
			switch canonicalHeading(title) {
			case prompts.HeadingDiscussed, prompts.HeadingDecisions, prompts.HeadingCommitments,
				prompts.HeadingOpenQuestions, prompts.HeadingRisks:
				return true
			}
		}
	}
	return false
}

// parseOverview reads the merge answer: the overview paragraph and each
// "###" (or any non-canonical heading) as a topic with its bullets.
func parseOverview(md string) (string, []Topic) {
	var overview []string
	topics := []Topic{}
	section := ""
	for _, raw := range strings.Split(md, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if level, title, ok := heading(line); ok {
			canonical := canonicalHeading(title)
			if level <= 2 && (canonical == prompts.HeadingOverview || canonical == prompts.HeadingTopics) {
				section = canonical
				continue
			}
			if section == prompts.HeadingTopics || section == "" {
				if len(topics) < prompts.MaxTopics {
					topics = append(topics, Topic{Title: bound(strings.Trim(title, "*"), MaxTopicTitle), Bullets: []string{}, Sources: []SourceRef{}})
				}
				section = prompts.HeadingTopics
			}
			continue
		}
		entry := cleanEntry(line)
		if entry == "" {
			continue
		}
		switch {
		case section == prompts.HeadingOverview:
			overview = append(overview, entry)
		case section == prompts.HeadingTopics && len(topics) > 0 && len(topics) <= prompts.MaxTopics:
			t := &topics[len(topics)-1]
			if len(t.Bullets) < MaxTopicBullets {
				t.Bullets = append(t.Bullets, bound(entry, MaxBulletBytes))
			}
		}
	}
	return bound(strings.Join(overview, " "), MaxSummaryBytes), topics
}

func bulletLines(md string) []string {
	var out []string
	for _, raw := range strings.Split(md, "\n") {
		line := strings.TrimSpace(raw)
		if _, _, ok := heading(line); ok || line == "" {
			continue
		}
		if entry := cleanEntry(line); entry != "" {
			out = append(out, entry)
		}
	}
	return out
}

// emptyEntry matches, folded, the "nothing here" lines models write under an
// empty heading instead of leaving it empty.
var emptyEntry = regexp.MustCompile(`^(none|no |nothing|n/a|-+$|ziadn|zatial ziadn|nic\b|nebol|neboli|nebyl|nie je|nie su|zadn|neni|bez )`)

func isEmptyEntry(s string) bool {
	return emptyEntry.MatchString(fold(strings.Trim(s, " *_()[].:-")))
}

func cleanEntry(line string) string {
	line = bulletPrefix.ReplaceAllString(line, "")
	line = strings.TrimSpace(strings.Trim(line, "*_"))
	line = strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(line, "[ ]"), "[x]"))
	if line == "" || isEmptyEntry(line) {
		return ""
	}
	return line
}

var thinking = regexp.MustCompile(`(?s)<think>.*?</think>`)

func stripThinking(s string) string { return strings.TrimSpace(thinking.ReplaceAllString(s, "")) }

// --- grounding ---

// pickSources returns up to three segments the text rests on: the ones
// sharing the most of its content words, rare words counting more. Text
// sharing fewer than two of its words with the part (one, for a one-word
// text) is not grounded in it: on the ADR 0022 prototype notes this kept
// 93 % of items and dropped the ones resting on a single common verb.
func (p *pipeline) pickSources(text string, segments []Segment) []SourceRef {
	words := contentTokens(text)
	if len(words) == 0 || len(segments) == 0 {
		return nil
	}
	matches := make([][]bool, len(segments))
	df := make([]int, len(words))
	for si, s := range segments {
		matches[si] = make([]bool, len(words))
		for wi, w := range words {
			for _, t := range p.segmentTokens(s) {
				if stemMatch(w, t) {
					matches[si][wi] = true
					df[wi]++
					break
				}
			}
		}
	}
	found := 0
	for _, n := range df {
		if n > 0 {
			found++
		}
	}
	if found < min(2, len(words)) {
		return nil
	}
	type scored struct {
		index int
		score float64
	}
	var ranked []scored
	for si := range segments {
		score := 0.0
		for wi := range words {
			// A word in most segments of the part says nothing about which.
			if matches[si][wi] && (len(segments) < 4 || df[wi] <= len(segments)/2) {
				score += 1 / float64(df[wi])
			}
		}
		if score > 0 {
			ranked = append(ranked, scored{si, score})
		}
	}
	sort.SliceStable(ranked, func(i, j int) bool { return ranked[i].score > ranked[j].score })
	var out []SourceRef
	for _, r := range ranked {
		if len(out) == 3 {
			break
		}
		out = append(out, SourceRef{Kind: "segment", ID: segments[r.index].ID})
	}
	return out
}

// saidIn finds the segment where every word of a phrase was said.
func (p *pipeline) saidIn(phrase string, segments []Segment) (SourceRef, bool) {
	var words []string
	for _, w := range strings.FieldsFunc(fold(phrase), notWordRune) {
		if utf8.RuneCountInString(w) > 2 || isDigits(w) {
			words = append(words, w)
		}
	}
	if len(words) == 0 {
		return SourceRef{}, false
	}
	for _, s := range segments {
		text := fold(s.Text)
		all := true
		for _, w := range words {
			if !strings.Contains(text, w) {
				all = false
				break
			}
		}
		if all {
			return SourceRef{Kind: "segment", ID: s.ID}, true
		}
	}
	return SourceRef{}, false
}

func (p *pipeline) segmentTokens(s Segment) []string {
	if t, ok := p.tokens[s.ID]; ok {
		return t
	}
	t := strings.FieldsFunc(fold(s.Text), notWordRune)
	p.tokens[s.ID] = t
	return t
}

// contentTokens are the distinct folded words of four or more letters — the
// client's support check uses the same floor and stem rule.
func contentTokens(text string) []string {
	var out []string
	seen := map[string]bool{}
	for _, w := range strings.FieldsFunc(fold(text), notWordRune) {
		if utf8.RuneCountInString(w) >= 4 && !seen[w] {
			seen[w] = true
			out = append(out, w)
		}
	}
	return out
}

// stemMatch mirrors ProtectedLiteralDetector.stemMatch on the client.
func stemMatch(a, b string) bool {
	if a == b {
		return true
	}
	ar, br := []rune(a), []rune(b)
	n := 0
	for n < len(ar) && n < len(br) && ar[n] == br[n] {
		n++
	}
	return n >= max(4, min(len(ar), len(br))-3)
}

// --- dedupe ---

func dedupeItems(items []Item) []Item {
	var kept []Item
	var keys [][]string
	for _, item := range items {
		key := dedupeKey(item.Text)
		if duplicate(key, keys) {
			continue
		}
		keys = append(keys, key)
		kept = append(kept, item)
	}
	if kept == nil {
		return []Item{}
	}
	return kept
}

func dedupeActions(items []ActionItem, owner func(ActionItem) string) []ActionItem {
	var kept []ActionItem
	var keys [][]string
	for _, item := range items {
		key := dedupeKey(owner(item) + " " + item.Text)
		if duplicate(key, keys) {
			continue
		}
		keys = append(keys, key)
		kept = append(kept, item)
	}
	if kept == nil {
		return []ActionItem{}
	}
	return kept
}

// dedupeKey is the text's content words; a text without any compares whole.
func dedupeKey(text string) []string {
	if key := contentTokens(text); len(key) > 0 {
		return key
	}
	return []string{" " + fold(text)}
}

// duplicate: at least 80 % of the words shared (Dice) with a kept entry.
func duplicate(key []string, kept [][]string) bool {
	for _, other := range kept {
		shared := 0
		set := map[string]bool{}
		for _, w := range other {
			set[w] = true
		}
		for _, w := range key {
			if set[w] {
				shared++
			}
		}
		if len(key)+len(other) > 0 && float64(2*shared)/float64(len(key)+len(other)) >= 0.8 {
			return true
		}
	}
	return false
}

// --- text helpers ---

// fold lowercases and strips the diacritics of Slovak, Czech and the other
// Latin languages a meeting here uses.
func fold(s string) string {
	return diacritics.Replace(strings.ToLower(strings.TrimSpace(s)))
}

var diacritics = strings.NewReplacer(
	"á", "a", "ä", "a", "à", "a", "â", "a", "ã", "a", "å", "a",
	"č", "c", "ç", "c", "ć", "c", "ď", "d",
	"é", "e", "ě", "e", "è", "e", "ê", "e", "ë", "e",
	"í", "i", "ì", "i", "î", "i", "ï", "i",
	"ĺ", "l", "ľ", "l", "ł", "l", "ň", "n", "ñ", "n", "ń", "n",
	"ó", "o", "ô", "o", "ö", "o", "ò", "o", "õ", "o", "ő", "o",
	"ŕ", "r", "ř", "r", "š", "s", "ś", "s", "ß", "ss", "ť", "t",
	"ú", "u", "ů", "u", "ü", "u", "ù", "u", "û", "u", "ű", "u",
	"ý", "y", "ÿ", "y", "ž", "z", "ź", "z", "ż", "z",
)

func notWordRune(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) }

func isDigits(s string) bool {
	for _, r := range s {
		if !unicode.IsDigit(r) {
			return false
		}
	}
	return s != ""
}

// slovakMarks are the diacritics of Slovak. czechMarks exist in Czech but not in
// Slovak: Czech prose carries them in about one letter in forty, so more than a
// name's worth marks a Slovak answer that drifted into Czech.
const (
	slovakMarks = "áäčďéíĺľňóôŕšťúýž"
	czechMarks  = "ěřů"
)

// languageOK is a coarse check for the requested prose language: Slovak text
// carries diacritics (about one letter in twenty) and no Czech-only letters
// beyond a name's worth, English text almost none. Text too short to tell
// passes — 60 letters for Slovak, 200 for English, where a few Slovak names
// must not read as the wrong language.
func (p *pipeline) languageOK(text string) bool {
	letters, slovak, czech := 0, 0, 0
	for _, r := range strings.ToLower(text) {
		if !unicode.IsLetter(r) {
			continue
		}
		letters++
		switch {
		case strings.ContainsRune(slovakMarks, r):
			slovak++
		case strings.ContainsRune(czechMarks, r):
			czech++
		}
	}
	if p.req.Meeting.LanguagePolicy.Output == "en" {
		return letters < 200 || float64(slovak+czech)/float64(letters) < 0.03
	}
	if letters < 60 {
		return true
	}
	// A name such as "Jiří" leaves a Slovak answer usable; Czech prose does not.
	czechTolerance := max(2, letters/500)
	return float64(slovak)/float64(letters) >= 0.01 && czech <= czechTolerance
}

// bound cuts s to at most n bytes on a rune boundary.
func bound(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	cut := n
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return strings.TrimSpace(s[:cut])
}

// joinBounded joins lines as "- " bullets up to n bytes, whole lines only.
func joinBounded(lines []string, n int) string {
	var b strings.Builder
	for _, line := range lines {
		line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "- "))
		if line == "" {
			continue
		}
		entry := "- " + line
		if b.Len() > 0 {
			entry = "\n" + entry
		}
		if b.Len()+len(entry) > n {
			if b.Len() == 0 {
				return bound(entry, n)
			}
			break
		}
		b.WriteString(entry)
	}
	return b.String()
}
