package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAdminListenFlags(t *testing.T) {
	none := func(string) string { return "" }
	dir := t.TempDir()
	for _, args := range [][]string{
		{"--admin-listen=0.0.0.0:8093", "--data-dir=" + dir},
		{"--admin-listen=localhost:8093", "--data-dir=" + dir},
		{"--listen=127.0.0.1:8091", "--admin-listen=127.0.0.1:8091", "--data-dir=" + dir},
		{"--admin-listen=127.0.0.1:8093"},
		{"--admin-listen=127.0.0.1:8093", "--data-dir=relative"},
	} {
		if _, err := parse(args, none, io.Discard); err == nil {
			t.Fatal("accepted", args)
		}
	}
	if _, err := parse([]string{"--admin-listen=127.0.0.1:8093", "--data-dir=" + dir}, none, io.Discard); err != nil {
		t.Fatal(err)
	}
}

func TestAdminTokenFile(t *testing.T) {
	dir := t.TempDir()
	token, err := adminToken(dir)
	if err != nil || len(token) != 64 {
		t.Fatal(token, err)
	}
	info, _ := os.Stat(filepath.Join(dir, adminTokenFile))
	if info.Mode().Perm() != 0o600 {
		t.Fatal("token file mode", info.Mode())
	}
	if again, _ := adminToken(dir); again != token {
		t.Fatal("token changed on the second start")
	}
	_ = os.Chmod(filepath.Join(dir, adminTokenFile), 0o644)
	if _, err := adminToken(dir); err == nil {
		t.Fatal("readable token file accepted")
	}
}

func TestRequestCounters(t *testing.T) {
	var c requestCounters
	for _, line := range []string{
		"flowd 2026/10/01 21:59:31 remote rewrite channel=115 user=1 device=1 op=2 wait_ms=0 duration_ms=542 code=ok\n",
		"flowd 2026/10/01 21:59:32 remote rewrite channel=9 user=1 device=1 op=2 code=busy\n",
		"flowd meeting 2026/10/01 21:21:43 remote meeting channel=97 user=1 device=1 op=1 kind=transcribe duration_ms=1 queue_depth=0 code=ok result_bytes=10\n",
		"flowd 2026/10/01 21:59:31 remote channel=115 purpose=session user=1 device=1 ops=2 duration_ms=9971 code=closed\n",
		"flowd 2026/10/01 21:59:31 request_id=x input_bytes=1 output_bytes=1 duration_ms=5 code=succeeded\n",
	} {
		_, _ = c.Write([]byte(line))
	}
	got := c.snapshot()
	if got["rewrite"] != (serviceCount{2, 1}) || got["meeting"] != (serviceCount{1, 0}) || got["dictation"] != (serviceCount{}) {
		t.Fatal(got)
	}
}

// The admin API answers only on --admin-listen, only with the token, and is not
// reachable through the remote listener (which Tailscale Serve exposes) or the
// main listener. Switching the summaries backend takes effect without a restart.
func TestAdminAPI(t *testing.T) {
	dir := initDataDir(t)
	models := func(id string) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprintf(w, `{"data":[{"id":%q}]}`, id)
		}))
	}
	rewriteModel, smart := models("localflow"), models("smart")
	defer rewriteModel.Close()
	defer smart.Close()
	addr, remoteAddr, adminAddr := freePort(t), freePort(t), freePort(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, []string{"serve", "--listen=" + addr, "--remote-listen=" + remoteAddr, "--admin-listen=" + adminAddr,
			"--data-dir=" + dir, "--backend=" + rewriteModel.URL, "--model=localflow"}, func(string) string { return "" }, io.Discard)
	}()
	defer func() {
		cancel()
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}()
	data, err := os.ReadFile(filepath.Join(dir, adminTokenFile))
	for deadline := time.Now().Add(3 * time.Second); err != nil && time.Now().Before(deadline); {
		time.Sleep(20 * time.Millisecond)
		data, err = os.ReadFile(filepath.Join(dir, adminTokenFile))
	}
	token := strings.TrimSpace(string(data))
	request := func(method, url, auth, body string) (int, string) {
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			req, _ := http.NewRequest(method, url, strings.NewReader(body))
			if auth != "" {
				req.Header.Set("Authorization", auth)
			}
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				time.Sleep(20 * time.Millisecond)
				continue
			}
			out, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			return resp.StatusCode, string(out)
		}
		t.Fatalf("%s never answered", url)
		return 0, ""
	}
	status := "http://" + adminAddr + "/v1/admin/status"
	if code, _ := request("GET", status, "", ""); code != 401 {
		t.Fatal("no token:", code)
	}
	if code, _ := request("GET", status, "Bearer wrong", ""); code != 403 {
		t.Fatal("wrong token:", code)
	}
	if code, _ := request("GET", status, token, ""); code != 403 {
		t.Fatal("token without Bearer:", code)
	}
	code, body := request("GET", status, "Bearer "+token, "")
	var s struct {
		Version  string
		Counters map[string]serviceCount
		Analysis struct{ Backend, Model string }
	}
	if err := json.Unmarshal([]byte(body), &s); code != 200 || err != nil || s.Version != "0.3.0" || len(s.Counters) != 5 || s.Analysis.Backend != "" {
		t.Fatal(code, body)
	}
	for _, other := range []string{remoteAddr, addr} {
		for _, path := range []string{"/v1/admin/status", "/v1/admin/analysis"} {
			if code, _ := request("GET", "http://"+other+path, "Bearer "+token, ""); code != 404 {
				t.Fatalf("%s%s answered %d", other, path, code)
			}
		}
	}
	analysis := "http://" + adminAddr + "/v1/admin/analysis"
	for _, bad := range []string{`{"backend":"http://192.168.1.2:8443/v1","model":"smart"}`, `{"backend":"file:///etc","model":"x"}`,
		`{"backend":"` + smart.URL + `"}`, `not json`} {
		if code, _ := request("PUT", analysis, "Bearer "+token, bad); code != 400 {
			t.Fatal("accepted", bad, code)
		}
	}
	if code, _ := request("PUT", analysis, "", `{"backend":""}`); code != 401 {
		t.Fatal("unauthenticated switch:", code)
	}
	health := func() string {
		_, body := request("GET", "http://"+addr+"/v1/analysis/health", "", "")
		var h struct{ Backend struct{ Model string } }
		_ = json.Unmarshal([]byte(body), &h)
		return h.Backend.Model
	}
	if got := health(); got != "localflow" {
		t.Fatal("before:", got)
	}
	code, body = request("PUT", analysis, "Bearer "+token, `{"backend":"`+smart.URL+`","model":"smart"}`)
	if code != 200 || !strings.Contains(body, `"model":"smart"`) {
		t.Fatal(code, body)
	}
	time.Sleep(5100 * time.Millisecond) // the handler caches a probe for 5 s
	if got := health(); got != "smart" {
		t.Fatal("after switch:", got)
	}
	if code, body = request("PUT", analysis, "Bearer "+token, `{"backend":""}`); code != 200 || !strings.Contains(body, `"backend":""`) {
		t.Fatal(code, body)
	}
}
