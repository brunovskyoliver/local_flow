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
	input := "Contact dev@example.com or see https://example.com/docs at 09:30 with 15 files."
	s, table := Shield(input)
	if s != "Contact ⟦E0⟧ or see ⟦E1⟧ at 09:30 with 15 files." {
		t.Fatal(s)
	}
	output, restored, err := Restore(s, table)
	if err != nil || output != input || restored != 2 {
		t.Fatal(output, restored, err)
	}
	for _, bad := range []string{
		strings.Replace(s, "⟦E0⟧", "", 1), strings.Replace(s, "⟦E1⟧", "", 1), s + "⟦E0⟧", s + "⟦E99⟧", s + "⟦broken", s + "⟧",
		// Visible values may not be dropped or changed.
		strings.Replace(s, "15 files", "files", 1), strings.Replace(s, "09:30", "9.30", 1), strings.Replace(s, "15", "fifteen", 1),
	} {
		if _, _, err := Restore(bad, table); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
}

// A spoken correction may drop the value it replaces, but only in favour of a
// nearby later value of the same class that survives.
func TestRestoreCorrections(t *testing.T) {
	for _, tc := range []struct {
		input, output, want string
		ok                  bool
	}{
		{"Set it to 30 seconds, wait, make it 60 seconds.", "Set it to 60 seconds.", "Set it to 60 seconds.", true},
		{"Meet on Tuesday, no, Wednesday at 15:00.", "Meet on Wednesday at 15:00.", "Meet on Wednesday at 15:00.", true},
		{"Stretneme sa v utorok, nie, v stredu.", "Stretneme sa v stredu.", "Stretneme sa v stredu.", true},
		{"Use 30, no 40, no 60 workers.", "Use 60 workers.", "Use 60 workers.", true},
		{"Use 5, sorry, 5 workers.", "Use 5 workers.", "Use 5 workers.", true},
		{"Deploy to 10.0.0.1, sorry, 10.0.0.2 tonight.", "Deploy to ⟦E1⟧ tonight.", "Deploy to 10.0.0.2 tonight.", true},
		// The replacement itself must survive.
		{"Set it to 30 seconds, wait, make it 60 seconds.", "Set it to 30 seconds.", "", false},
		{"Deploy to 10.0.0.1, sorry, 10.0.0.2 tonight.", "Deploy to ⟦E0⟧ tonight.", "", false},
		// A different class does not supersede.
		{"Meet on Tuesday, no, at 15:00.", "Meet at 15:00.", "", false},
		// Too far apart to be a correction.
		{"Order 5 boxes for the warehouse downstairs, and later this month, once the budget clears, order 6 cables.", "Order boxes, then 6 cables.", "", false},
	} {
		_, table := Shield(tc.input)
		got, restored, err := Restore(tc.output, table)
		if (err == nil) != tc.ok || got != tc.want {
			t.Errorf("%q → %q: got %q, %v", tc.input, tc.output, got, err)
		}
		if tc.ok && restored > len(table.Shielded) {
			t.Errorf("%q: restored %d of %d", tc.input, restored, len(table.Shielded))
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
			for _, e := range append(table.Shielded, table.Checked...) {
				if e.Value == p.Value {
					found = true
				}
			}
			if !found {
				t.Errorf("%s: unshielded %s %q", item.ID, p.Class, p.Value)
			}
		}
	}
}
