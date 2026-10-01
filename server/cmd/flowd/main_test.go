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
	"path/filepath"
	"strings"
	"testing"
	"time"

	"localflow/server/internal/analysis"
)

func TestFlags(t *testing.T) {
	env := func(key string) string {
		return map[string]string{"LOCALFLOW_REWRITE_TOKEN": "client-secret", "LOCALFLOW_BACKEND_TOKEN": "backend-secret"}[key]
	}
	c, err := parse([]string{"--shield=off", "--debug-delay=30s", "--protocol-versions=2", "--first-token-timeout=7s", "--backend-timeout=40s"}, env, io.Discard)
	if err != nil || c.shield || c.versions[0] != 2 || len(c.rewriteVersions) != 1 || c.rewriteVersions[0] != 2 || c.backend.DebugDelay != 30*time.Second || c.backend.Token != "backend-secret" || c.token != "client-secret" {
		t.Fatal(c, err)
	}
	for _, args := range [][]string{{"--shield=maybe"}, {"--protocol-versions=0"}, {"--rewrite-protocol-versions=1,x"}, {"--rewrite-protocol-versions="}, {"--backend-timeout=0s"}, {"--first-token-timeout=-1s"}, {"--debug-delay=-1s"}, {"--analysis-timeout=0s"}, {"--analysis-first-token-timeout=-1s"}, {"--listen=0.0.0.0:8080"}, {"extra"}} {
		if _, err := parse(args, func(string) string { return "" }, io.Discard); err == nil {
			t.Fatal(args)
		}
	}
	// Request dumping exists only in localflow_debug builds.
	if _, err := parse([]string{"--analysis-dump-requests=/tmp/x"}, func(string) string { return "" }, io.Discard); (err == nil) != analysis.DebugBuild {
		t.Fatal("--analysis-dump-requests", err)
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

func none(string) string { return "" }

// Remote serving is off unless --remote-listen is given; its flags are parsed
// and stored, and the defaults follow contracts/flowd-cli.md.
func TestRemoteFlags(t *testing.T) {
	c, err := parse(nil, none, io.Discard)
	if err != nil || c.remote.listen != "" || fmt.Sprint(c.remote.appleAudience) != "[org.localflow.LocalFlow]" || len(c.remote.googleClientIDs) != 0 {
		t.Fatalf("%+v %v", c.remote, err)
	}
	dir := t.TempDir()
	c, err = parse([]string{"--remote-listen=127.0.0.1:18090", "--data-dir=" + dir, "--apple-audience=org.localflow.LocalFlow,org.localflow.LocalFlow.dev",
		"--google-client-id=a.apps.googleusercontent.com,b.apps.googleusercontent.com", "--speech-worker=/opt/flowd-speech", "--speech-models=/opt/models", "--dev",
		"--meeting-models=/opt/meeting-models", "--meeting-helper=/opt/localflow-whisper-engine"}, none, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	r := c.remote
	if r.listen != "127.0.0.1:18090" || r.dataDir != dir || len(r.appleAudience) != 2 || r.appleAudience[1] != "org.localflow.LocalFlow.dev" ||
		len(r.googleClientIDs) != 2 || r.speechWorker != "/opt/flowd-speech" || r.speechModels != "/opt/models" || !r.dev ||
		r.meetingModels != "/opt/meeting-models" || r.meetingHelper != "/opt/localflow-whisper-engine" {
		t.Fatalf("%+v", r)
	}
	c, err = parse([]string{"--remote-listen=[::1]:8090", "--data-dir=" + dir}, none, io.Discard)
	executable, _ := os.Executable()
	if err != nil || c.remote.speechModels != filepath.Join(dir, "Models") || c.remote.speechWorker != filepath.Join(filepath.Dir(executable), "flowd-speech") ||
		c.remote.meetingModels != c.remote.speechModels || c.remote.meetingHelper != filepath.Join(filepath.Dir(executable), "localflow-whisper-engine") {
		t.Fatalf("defaults %+v %v", c.remote, err)
	}
	for _, args := range [][]string{
		{"--remote-listen=0.0.0.0:8090", "--data-dir=" + dir},
		{"--remote-listen=192.168.1.4:8090", "--data-dir=" + dir},
		{"--remote-listen=localhost:8090", "--data-dir=" + dir},
		{"--remote-listen=8090", "--data-dir=" + dir},
		{"--remote-listen=127.0.0.1:8090"},
		{"--remote-listen=127.0.0.1:8090", "--data-dir=relative/dir"},
		{"--remote-listen=127.0.0.1:8090", "--data-dir=" + dir, "--apple-audience="},
		{"--remote-listen=127.0.0.1:8090", "--data-dir=" + dir, "--apple-audience=a,,b"},
		{"--remote-listen=127.0.0.1:8080", "--data-dir=" + dir},
	} {
		if _, err := parse(args, none, io.Discard); err == nil {
			t.Errorf("%q accepted", args)
		}
	}
}

// --test-issuer, --test-jwks and --debug-busy exist only in localflow_debug
// builds.
func TestRemoteDebugFlags(t *testing.T) {
	args := []string{"--test-issuer=http://127.0.0.1:9999", "--test-jwks=/tmp/jwks.json", "--debug-busy"}
	c, err := parse(args, none, io.Discard)
	if !remoteDebugBuild {
		for _, arg := range args {
			if _, err := parse([]string{arg}, none, io.Discard); err == nil {
				t.Errorf("%s accepted without -tags localflow_debug", arg)
			}
		}
		return
	}
	if err != nil || c.remote.testIssuer != "http://127.0.0.1:9999" || c.remote.testJWKS != "/tmp/jwks.json" || !c.remote.debugBusy {
		t.Fatalf("%+v %v", c.remote, err)
	}
}

// initDataDir runs flowd admin init against a fake keychain.
func initDataDir(t *testing.T) string {
	t.Helper()
	useKeychain(t)
	dir := filepath.Join(t.TempDir(), "LocalFlow Server Dev")
	if _, err := admin("--data-dir", dir, "init"); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestRemoteServeRefusals(t *testing.T) {
	dir := initDataDir(t)
	serve := func(dataDir string, extra ...string) error {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		args := append([]string{"serve", "--listen=" + freePort(t), "--remote-listen=" + freePort(t), "--data-dir=" + dataDir}, extra...)
		return run(ctx, args, none, io.Discard)
	}
	if err := serve(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("missing data directory accepted")
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := serve(dir); err == nil || !strings.Contains(err.Error(), "private") {
		t.Fatalf("0755 data directory accepted: %v", err)
	}
	_ = os.Chmod(dir, 0o700)
	if err := serve(dir, "--dev"); err == nil || !strings.Contains(err.Error(), "admin init") {
		t.Fatalf("missing identity key accepted: %v", err)
	}
	empty := filepath.Join(t.TempDir(), "empty")
	_ = os.Mkdir(empty, 0o700)
	if err := serve(empty); err == nil || !strings.Contains(err.Error(), "admin init") {
		t.Fatalf("data directory without a key accepted: %v", err)
	}
}

// With --remote-listen, flowd serves /v1/remote/* on the second listener only;
// the existing listener and routes are unchanged.
func TestRemoteServe(t *testing.T) {
	dir := initDataDir(t)
	addr, remoteAddr := freePort(t), freePort(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, []string{"serve", "--listen=" + addr, "--remote-listen=" + remoteAddr, "--data-dir=" + dir}, none, io.Discard)
	}()
	defer func() {
		cancel()
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}()
	get := func(url string) (int, string) {
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			resp, err := http.Get(url)
			if err != nil {
				time.Sleep(20 * time.Millisecond)
				continue
			}
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			return resp.StatusCode, string(body)
		}
		t.Fatalf("%s never answered", url)
		return 0, ""
	}
	status, body := get("http://" + remoteAddr + "/v1/remote/identity")
	var identity struct {
		Server      string `json:"server"`
		Fingerprint string `json:"fingerprint"`
	}
	_ = json.Unmarshal([]byte(body), &identity)
	if status != 200 || identity.Server != "flowd/0.3.0" || len(identity.Fingerprint) != 39 {
		t.Fatal(status, body)
	}
	if status, _ := get("http://" + remoteAddr + "/v1/rewrite/health"); status != 404 {
		t.Fatal("rewrite on the remote listener", status)
	}
	if status, _ := get("http://" + addr + "/v1/remote/identity"); status != 404 {
		t.Fatal("remote routes on the main listener", status)
	}
	if status, _ := get("http://" + addr + "/v1/rewrite/health"); status != 200 {
		t.Fatal("rewrite health", status)
	}
}
