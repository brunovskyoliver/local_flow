package analysis

import (
	"encoding/json"
	"strconv"
)

// idAliases swaps the UUIDs a model must copy back — segment and participant
// ids — for short tokens ("s12", "p2") in the prompt, and maps the answer back
// before validation. A 4B model garbles one character of a 36-character UUID
// often enough to fail whole runs, and every UUID costs ~20 tokens each way.
// The map is a pure function of the request, so validation rebuilds it.
type idAliases struct {
	short map[string]string // UUID → alias
	long  map[string]string // alias → UUID
}

func newAliases(req *Request) idAliases {
	a := idAliases{map[string]string{}, map[string]string{}}
	counts := map[string]int{}
	add := func(id, prefix string) {
		if _, ok := a.short[id]; ok || id == "" {
			return
		}
		counts[prefix]++
		alias := prefix + strconv.Itoa(counts[prefix])
		a.short[id] = alias
		a.long[alias] = id
	}
	for _, p := range req.Participants {
		add(p.SpeakerID, "p")
	}
	for _, s := range req.Segments {
		add(s.ID, "s")
	}
	for _, p := range req.Partials {
		collectSources(p, func(kind, id string) {
			if kind == "segment" {
				add(id, "s")
			}
		})
	}
	return a
}

// mapIDs rewrites every segment source and participant owner id found in m;
// ids absent from m stay as they are, so validation still rejects them.
func mapIDs(a *Analysis, m map[string]string) {
	source := func(s *SourceRef) {
		if s.Kind == "segment" {
			if v, ok := m[s.ID]; ok {
				s.ID = v
			}
		}
	}
	sources := func(list []SourceRef) {
		for i := range list {
			source(&list[i])
		}
	}
	sources(a.Summary.Sources)
	for i := range a.Topics {
		sources(a.Topics[i].Sources)
	}
	for _, items := range [][]Item{a.Decisions, a.NextSteps, a.OpenQuestions, a.Risks} {
		for i := range items {
			sources(items[i].Sources)
		}
	}
	for i := range a.ActionItems {
		item := &a.ActionItems[i]
		sources(item.Sources)
		if item.Due.Source != nil {
			source(item.Due.Source)
		}
		if item.Owner.SpeakerID != nil {
			if v, ok := m[*item.Owner.SpeakerID]; ok {
				item.Owner.SpeakerID = &v
			}
		}
	}
}

// aliasedDocument is the request evidence as the model reads it: short ids in
// place of UUIDs, and no known_speaker_id — the model never needs it.
func aliasedDocument(req *Request, a idAliases) (map[string]any, error) {
	alias := func(id string) string {
		if v, ok := a.short[id]; ok {
			return v
		}
		return id
	}
	participants := make([]Participant, len(req.Participants))
	for i, p := range req.Participants {
		p.SpeakerID = alias(p.SpeakerID)
		p.KnownSpeakerID = nil
		participants[i] = p
	}
	doc := map[string]any{"meeting": req.Meeting, "participants": participants}
	if req.Segments != nil {
		segments := make([]Segment, len(req.Segments))
		for i, s := range req.Segments {
			s.ID = alias(s.ID)
			if s.SpeakerID != nil {
				id := alias(*s.SpeakerID)
				s.SpeakerID = &id
			}
			segments[i] = s
		}
		doc["segments"] = segments
	}
	if req.Notes != nil {
		doc["notes"] = req.Notes
	}
	if req.Partials != nil {
		// A JSON round trip is the deep copy: the request's partials stay intact.
		data, err := json.Marshal(req.Partials)
		if err != nil {
			return nil, err
		}
		var partials []Analysis
		if err := json.Unmarshal(data, &partials); err != nil {
			return nil, err
		}
		for i := range partials {
			mapIDs(&partials[i], a.short)
		}
		doc["partials"] = partials
	}
	return doc, nil
}
