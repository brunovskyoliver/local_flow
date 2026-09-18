package shield

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestDetectorClasses(t *testing.T) {
	for _, tc := range []struct{ class, yes, no string }{
		{"ip", "192.168.1.20", "999.300.1.1"}, {"ip", "2001:db8::1", "hello:world"},
		{"url", "https://example.com/status", "example word"}, {"email", "dev@example.com", "someone@"},
		{"path", "/etc/localflow/config.json", "and/or"}, {"version", "v1.2.3", "version"},
		{"currency", "USD 500", "USD"}, {"currency", "€120.50", "euro"},
		{"number", "15", "abc15def"}, {"date", "Monday", "monthly"}, {"date", "2026-10-02", "today"},
		{"time", "09:30", "99:99"},
	} {
		t.Run(tc.class+tc.yes, func(t *testing.T) {
			found := false
			for _, m := range Detect(tc.yes) {
				if m.Class == tc.class && m.Value == tc.yes {
					found = true
				}
			}
			if !found {
				t.Fatalf("missing %s", tc.yes)
			}
			for _, m := range Detect(tc.no) {
				if m.Class == tc.class {
					t.Fatalf("false positive: %+v", m)
				}
			}
		})
	}
}
func TestRoundTrip(t *testing.T) {
	input := "Contact dev@example.com at 09:30 with 15 files."
	s, table := Shield(input)
	if s != "Contact ⟦E0⟧ at ⟦E1⟧ with ⟦E2⟧ files." {
		t.Fatal(s)
	}
	output, err := Restore(s, table)
	if err != nil || output != input {
		t.Fatal(output, err)
	}
	for _, bad := range []string{strings.Replace(s, "⟦E0⟧", "", 1), s + "⟦E0⟧", s + "⟦E99⟧", s + "⟦broken", s + "⟧"} {
		if _, err := Restore(bad, table); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
}
func TestCorpusCoverage(t *testing.T) {
	data, err := os.ReadFile("../../../../fixtures/rewrite/corpus-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var corpus struct {
		Items []struct {
			ID, Text  string
			Protected []struct{ Class, Value string }
		}
	}
	if err := json.Unmarshal(data, &corpus); err != nil {
		t.Fatal(err)
	}
	for _, item := range corpus.Items {
		_, table := Shield(item.Text)
		for _, p := range item.Protected {
			if p.Class == "identifier" {
				continue
			}
			found := false
			for _, v := range table {
				if v == p.Value {
					found = true
				}
			}
			if !found {
				t.Errorf("%s: unshielded %s %q", item.ID, p.Class, p.Value)
			}
		}
	}
}
