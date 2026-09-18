package main

import (
	"bytes"
	"context"
	"io"
	"strings"
	"testing"
	"time"
)

func TestFlags(t *testing.T) {
	env := func(key string) string {
		return map[string]string{"LOCALFLOW_REWRITE_TOKEN": "client-secret", "LOCALFLOW_BACKEND_TOKEN": "backend-secret"}[key]
	}
	c, err := parse([]string{"--shield=off", "--debug-delay=30s", "--protocol-versions=2", "--first-token-timeout=7s", "--backend-timeout=40s"}, env, io.Discard)
	if err != nil || c.shield || c.versions[0] != 2 || c.backend.DebugDelay != 30*time.Second || c.backend.Token != "backend-secret" || c.token != "client-secret" {
		t.Fatal(c, err)
	}
	for _, args := range [][]string{{"--shield=maybe"}, {"--protocol-versions=0"}, {"--backend-timeout=0s"}, {"--first-token-timeout=-1s"}, {"--debug-delay=-1s"}, {"--listen=0.0.0.0:8080"}, {"extra"}} {
		if _, err := parse(args, func(string) string { return "" }, io.Discard); err == nil {
			t.Fatal(args)
		}
	}
}
func TestHelpAndShutdown(t *testing.T) {
	var out bytes.Buffer
	if err := run(context.Background(), nil, func(string) string { return "" }, &out); err != nil || !strings.Contains(out.String(), "0.2.0") {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if err := run(ctx, []string{"rewrite", "--listen=127.0.0.1:0"}, func(string) string { return "" }, io.Discard); err != nil {
		t.Fatal(err)
	}
}
