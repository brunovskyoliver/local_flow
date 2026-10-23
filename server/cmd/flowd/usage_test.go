package main

import (
	"bytes"
	"context"
	"localflow/server/internal/usage"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestUsageStartupIsolation(t *testing.T) {
	for _, kind := range []string{"database", "configuration"} {
		t.Run(kind, func(t *testing.T) {
			dir := t.TempDir()
			config := ""
			if kind == "database" {
				if err := os.WriteFile(filepath.Join(dir, "usage.sqlite"), []byte("broken-database-fixture"), 0600); err != nil {
					t.Fatal(err)
				}
			} else {
				config = filepath.Join(dir, "bad-config")
				if err := os.WriteFile(config, []byte(`{"credential":"private-fixture-marker"}`), 0600); err != nil {
					t.Fatal(err)
				}
			}
			var logs bytes.Buffer
			s, e := openOptionalUsage(context.Background(), dir, config, func(usage.Identity) bool { return true }, log.New(&logs, "", 0))
			if e != nil {
				t.Fatal("bad configuration enabled exporter")
			}
			if s != nil {
				defer s.Close()
			}
			if kind == "database" && s != nil {
				t.Fatal("bad database enabled capability")
			}
			if kind == "configuration" && s == nil {
				t.Fatal("local accounting lost with export config")
			}
			if strings.Contains(logs.String(), "private-fixture-marker") || strings.Contains(logs.String(), dir) {
				t.Fatal("sensitive startup diagnostics")
			}
			if logs.Len() == 0 {
				t.Fatal("missing availability notice")
			}
		})
	}
}
