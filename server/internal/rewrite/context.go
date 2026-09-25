package rewrite

import (
	"bytes"
	"encoding/json"
	"unicode"
)

// Context bounds from specs/012-app-context-awareness/data-model.md. The
// character limits count user-perceived characters as the client does.
const (
	ContextSchemaVersion   = 1
	MaxContextBytes        = 8192
	MaxContextTerms        = 40
	MaxTermBytes           = 64
	MaxAppNameBytes        = 128
	MaxWindowTitleChars    = 200
	MaxBeforeCursorChars   = 1000
	MaxAfterCursorChars    = 300
	MaxSelectedTextChars   = 2000
	contextOpen            = "<screen_context>"
	contextClose           = "</screen_context>"
	escapedLessThanLiteral = `\u003c`
)

var (
	AppCategories = []string{"email", "work_chat", "personal_chat", "code", "terminal", "document", "other"}
	FieldKinds    = []string{"single_line", "multi_line", "search", "code", "terminal", "unknown"}
	ContextParts  = []string{"window_title", "before_cursor", "after_cursor", "selected_text"}
	TermKinds     = []string{"name", "identifier"}
)

// Context is the parsed v2 reference snapshot. It is used for validation and
// the prompt gates only; the prompt renders the bytes as received.
type Context struct {
	SchemaVersion int
	AppName       *string
	AppCategory   string
	FieldKind     string
	WindowTitle   *string
	BeforeCursor  *string
	AfterCursor   *string
	SelectedText  *string
	Terms         []Term
	Truncated     []string
	StyleHints    bool
}

// Term is one candidate spelling taken from a context part.
type Term struct {
	Text   string
	Source string
	Kind   string
}

// DecodeContext validates the closed context object. Every failure is
// invalid_request; the reason never contains context text.
func DecodeContext(data []byte) (Context, error) {
	var c Context
	bad := func(reason string) (Context, error) {
		return Context{}, &RequestError{CodeInvalidRequest, "context " + reason}
	}
	if len(data) > MaxContextBytes {
		return bad("over byte limit")
	}
	raw, err := closedObject(data, []string{"schema_version", "app_category", "field_kind", "terms", "truncated", "style_hints"}, []string{"app_name", "window_title", "before_cursor", "after_cursor", "selected_text"})
	if err != nil {
		return bad(err.Error())
	}
	if string(bytes.TrimSpace(raw["schema_version"])) != "1" {
		return bad("schema_version unsupported")
	}
	c.SchemaVersion = ContextSchemaVersion
	if json.Unmarshal(raw["app_category"], &c.AppCategory) != nil || !contains(AppCategories, c.AppCategory) {
		return bad("app_category invalid")
	}
	if json.Unmarshal(raw["field_kind"], &c.FieldKind) != nil || !contains(FieldKinds, c.FieldKind) {
		return bad("field_kind invalid")
	}
	parts := []struct {
		key   string
		dst   **string
		limit int
		bytes bool
	}{
		{"app_name", &c.AppName, MaxAppNameBytes, true},
		{"window_title", &c.WindowTitle, MaxWindowTitleChars, false},
		{"before_cursor", &c.BeforeCursor, MaxBeforeCursorChars, false},
		{"after_cursor", &c.AfterCursor, MaxAfterCursorChars, false},
		{"selected_text", &c.SelectedText, MaxSelectedTextChars, false},
	}
	for _, p := range parts {
		value, ok := raw[p.key]
		if !ok {
			continue
		}
		if json.Unmarshal(value, p.dst) != nil {
			return bad(p.key + " not a string")
		}
		if *p.dst == nil {
			continue
		}
		n := CharacterCount(**p.dst)
		if p.bytes {
			n = len(**p.dst)
		}
		if n > p.limit {
			return bad(p.key + " over limit")
		}
	}
	var terms []json.RawMessage
	if json.Unmarshal(raw["terms"], &terms) != nil || terms == nil {
		return bad("terms not an array")
	}
	if len(terms) > MaxContextTerms {
		return bad("too many terms")
	}
	for _, data := range terms {
		fields, err := closedObject(data, []string{"text", "source", "kind"}, nil)
		if err != nil {
			return bad("term " + err.Error())
		}
		var t Term
		if json.Unmarshal(fields["text"], &t.Text) != nil || t.Text == "" || len(t.Text) > MaxTermBytes {
			return bad("term text invalid")
		}
		if json.Unmarshal(fields["source"], &t.Source) != nil || !contains(ContextParts, t.Source) {
			return bad("term source invalid")
		}
		if json.Unmarshal(fields["kind"], &t.Kind) != nil || !contains(TermKinds, t.Kind) {
			return bad("term kind invalid")
		}
		c.Terms = append(c.Terms, t)
	}
	if json.Unmarshal(raw["truncated"], &c.Truncated) != nil || c.Truncated == nil {
		return bad("truncated not an array")
	}
	seen := map[string]bool{}
	for _, part := range c.Truncated {
		if !contains(ContextParts, part) || seen[part] {
			return bad("truncated invalid")
		}
		seen[part] = true
	}
	if value := string(bytes.TrimSpace(raw["style_hints"])); value != "true" && value != "false" {
		return bad("style_hints not a boolean")
	}
	c.StyleHints = string(bytes.TrimSpace(raw["style_hints"])) == "true"
	return c, nil
}

// closedObject decodes one JSON object whose keys must be a subset of
// required+optional and include every required key.
func closedObject(data []byte, required, optional []string) (map[string]json.RawMessage, error) {
	var raw map[string]json.RawMessage
	if len(bytes.TrimSpace(data)) == 0 || bytes.TrimSpace(data)[0] != '{' || json.Unmarshal(data, &raw) != nil {
		return nil, errString("not an object")
	}
	for key := range raw {
		if !contains(required, key) && !contains(optional, key) {
			return nil, errString("unknown field")
		}
	}
	for _, key := range required {
		if _, ok := raw[key]; !ok {
			return nil, errString("missing field " + key)
		}
	}
	return raw, nil
}

type errString string

func (e errString) Error() string { return string(e) }

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// CharacterCount approximates Swift's extended grapheme cluster count without
// ever exceeding it for text the client produced: combining and spacing marks,
// joiners, variation selectors, emoji modifiers and tag characters extend the
// previous character, a character after ZWJ or a conjunct virama joins it, CRLF
// is one character and a regional indicator pair is one flag.
func CharacterCount(s string) int {
	n, indicators := 0, 0
	var prev rune
	for i, r := range s {
		switch {
		case i > 0 && (prev == 0x200D || isConjunctLinker(prev)):
		case r == '\n' && prev == '\r':
		case unicode.In(r, unicode.Mn, unicode.Me, unicode.Mc):
		case r == 0x200C || r == 0x200D:
		case r >= 0xFE00 && r <= 0xFE0F, r >= 0xE0100 && r <= 0xE01EF:
		case r >= 0x1F3FB && r <= 0x1F3FF, r >= 0xE0020 && r <= 0xE007F:
		case r >= 0x1F1E6 && r <= 0x1F1FF:
			indicators++
		default:
			n++
		}
		prev = r
	}
	return n + (indicators+1)/2
}

// isConjunctLinker reports the Indic viramas that join the next consonant into
// one cluster (Unicode 15.1 InCB=Linker).
func isConjunctLinker(r rune) bool {
	switch r {
	case 0x094D, 0x09CD, 0x0ACD, 0x0B4D, 0x0C4D, 0x0D4D:
		return true
	}
	return false
}

// RenderContext delimits the context JSON for the system message. Every '<' is
// replaced by its JSON escape, which keeps the JSON equal in value and means no
// context value can close the tag.
func RenderContext(data []byte) string {
	escaped := bytes.ReplaceAll(bytes.TrimSpace(data), []byte("<"), []byte(escapedLessThanLiteral))
	return contextOpen + string(escaped) + contextClose
}
