package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func TestFlags(t *testing.T) {
	env := func(key string) string {
		return map[string]string{"LOCALFLOW_REWRITE_TOKEN": "client-secret", "LOCALFLOW_BACKEND_TOKEN": "backend-secret"}[key]
	}
	c, err := parse([]string{"--shield=off", "--debug-delay=30s", "--protocol-versions=2", "--first-token-timeout=7s", "--backend-timeout=40s"}, env, io.Discard)
	if err != nil || c.shield || c.versions[0] != 2 || len(c.rewriteVersions) != 1 || c.rewriteVersions[0] != 2 || c.backend.DebugDelay != 30*time.Second || c.backend.Token != "backend-secret" || c.token != "client-secret" {
		t.Fatal(c, err)
	}
	for _, args := range [][]string{{"--shield=maybe"}, {"--protocol-versions=0"}, {"--rewrite-protocol-versions=1,x"}, {"--rewrite-protocol-versions="}, {"--backend-timeout=0s"}, {"--first-token-timeout=-1s"}, {"--debug-delay=-1s"}, {"--analysis-timeout=0s"}, {"--analysis-first-token-timeout=-1s"}, {"--listen=0.0.0.0:8080"}, {"extra"}, {"--analysis-dump-requests=/tmp/x"}} {
		if _, err := parse(args, func(string) string { return "" }, io.Discard); err == nil {
			t.Fatal(args)
		}
	}
}

// Rewrite advertises 1 and 2 by default while analysis keeps its own list.
func TestRewriteProtocolVersions(t *testing.T) {
	none := func(string) string { return "" }
	for _, tc := range []struct {
		args              []string
		analysis, rewrite string
	}{
		{nil, "[1]", "[1 2]"},
		{[]string{"--rewrite-protocol-versions=1"}, "[1]", "[1]"},
		{[]string{"--protocol-versions=2"}, "[2]", "[2]"},
		{[]string{"--protocol-versions=1", "--rewrite-protocol-versions=2"}, "[1]", "[2]"},
	} {
		c, err := parse(tc.args, none, io.Discard)
		if err != nil || fmt.Sprint(c.versions) != tc.analysis || fmt.Sprint(c.rewriteVersions) != tc.rewrite {
			t.Fatal(tc.args, c.versions, c.rewriteVersions, err)
		}
	}
	addr := freePort(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- run(ctx, []string{"serve", "--listen=" + addr}, none, io.Discard) }()
	defer func() {
		cancel()
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}()
	versions := map[string]string{}
	deadline := time.Now().Add(3 * time.Second)
	for _, path := range []string{"/v1/rewrite/health", "/v1/analysis/health"} {
		for time.Now().Before(deadline) {
			resp, err := http.Get("http://" + addr + path)
			if err != nil {
				time.Sleep(20 * time.Millisecond)
				continue
			}
			var health struct {
				ProtocolVersions []int `json:"protocol_versions"`
			}
			_ = json.NewDecoder(resp.Body).Decode(&health)
			resp.Body.Close()
			versions[path] = fmt.Sprint(health.ProtocolVersions)
			break
		}
	}
	if versions["/v1/rewrite/health"] != "[1 2]" || versions["/v1/analysis/health"] != "[1]" {
		t.Fatal(versions)
	}
}

func TestAnalysisFlags(t *testing.T) {
	c, err := parse([]string{
		"--analysis-concurrency=2", "--analysis-input-bytes=4096",
		"--analysis-output-tokens=1024", "--analysis-output-tokens-chunk=512",
		"--analysis-context-tokens=8192", "--analysis-timeout=60s",
		"--analysis-first-token-timeout=5s", "--analysis-queue-wait=10s",
		"--analysis-preempt=false",
	}, func(string) string { return "" }, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	a := c.analysis
	if a.Concurrency != 2 || a.InputBytes != 4096 || a.OutputTokensFull != 1024 ||
		a.OutputTokensChunk != 512 || a.ContextTokens != 8192 ||
		a.Timeout != 60*time.Second || a.FirstTokenTimeout != 5*time.Second ||
		a.QueueWait != 10*time.Second || a.Preempt {
		t.Fatalf("analysis flags: %+v", a)
	}
}

// serve mounts rewrite and analysis on one listener; --analysis=false turns
// the analysis paths into 404 while rewrite keeps working.
func TestServeSubcommand(t *testing.T) {
	for _, enabled := range []bool{true, false} {
		t.Run(fmt.Sprint(enabled), func(t *testing.T) {
			addr := freePort(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() {
				args := []string{"serve", "--listen=" + addr}
				if !enabled {
					args = append(args, "--analysis=false")
				}
				done <- run(ctx, args, func(string) string { return "" }, io.Discard)
			}()
			deadline := time.Now().Add(3 * time.Second)
			var healthStatus int
			var health map[string]any
			for time.Now().Before(deadline) {
				resp, err := http.Get("http://" + addr + "/v1/analysis/health")
				if err != nil {
					time.Sleep(20 * time.Millisecond)
					continue
				}
				healthStatus = resp.StatusCode
				_ = json.NewDecoder(resp.Body).Decode(&health)
				resp.Body.Close()
				break
			}
			if enabled {
				if healthStatus != 200 || health["service"] != "localflow-analysis" {
					t.Fatalf("analysis health: %d %v", healthStatus, health)
				}
			} else if healthStatus != 404 {
				t.Fatalf("--analysis=false should 404, got %d", healthStatus)
			}
			// Rewrite endpoint is served on the same listener either way.
			resp, err := http.Get("http://" + addr + "/v1/rewrite/health")
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Close()
			if resp.StatusCode != 200 {
				t.Fatalf("rewrite health: %d", resp.StatusCode)
			}
			cancel()
			if err := <-done; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestRewriteAlias(t *testing.T) {
	addr := freePort(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, []string{"rewrite", "--listen=" + addr}, func(string) string { return "" }, io.Discard)
	}()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get("http://" + addr + "/v1/analysis/health")
		if err == nil {
			resp.Body.Close()
			cancel()
			if err := <-done; err != nil {
				t.Fatal(err)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("rewrite alias did not serve analysis")
}

func freePort(t *testing.T) string {
	t.Helper()
	l, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().String()
}

func TestHelpAndShutdown(t *testing.T) {
	var out bytes.Buffer
	if err := run(context.Background(), nil, func(string) string { return "" }, &out); err != nil || !strings.Contains(out.String(), "0.3.0") {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if err := run(ctx, []string{"rewrite", "--listen=127.0.0.1:0"}, func(string) string { return "" }, io.Discard); err != nil {
		t.Fatal(err)
	}
}

// The request log rotates once past its limit: the live file restarts and
// the previous one survives as .1, so disk use stays under twice the limit.
func TestCappedFileRotates(t *testing.T) {
	path := t.TempDir() + "/flowd.log"
	file := &cappedFile{path: path, limit: 10}
	defer file.Close()
	for _, line := range []string{"aaaaaa\n", "bbbbbb\n", "cccccc\n"} {
		if _, err := file.Write([]byte(line)); err != nil {
			t.Fatal(err)
		}
	}
	live, _ := os.ReadFile(path)
	rotated, _ := os.ReadFile(path + ".1")
	if string(live) != "cccccc\n" || string(rotated) != "bbbbbb\n" {
		t.Fatalf("live %q rotated %q", live, rotated)
	}
}
