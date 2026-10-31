package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"testing"
	"time"
)

// TestE2EServe is the server half of scripts/test-pairing-e2e.sh, skipped unless
// LOCALFLOW_E2E_INFO names a file. It runs flowd's own serve path in this test
// binary on loopback, with a temp data dir and the fake Keychain that a built flowd
// can't use (keychainRunner has no production override, on purpose). It writes the
// origin and a fresh token to that file and serves until <file>.done appears.
func TestE2EServe(t *testing.T) {
	info := os.Getenv("LOCALFLOW_E2E_INFO")
	if info == "" {
		t.Skip("LOCALFLOW_E2E_INFO not set")
	}
	dir := initDataDir(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	remote := freePort(t)
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, []string{"serve", "--listen=" + freePort(t), "--remote-listen=" + remote, "--data-dir=" + dir,
			"--backend=http://127.0.0.1:9/v1", "--model=none"}, none, io.Discard)
	}()
	origin := "http://" + remote
	for ready := false; !ready; {
		select {
		case err := <-done:
			t.Fatal("flowd stopped:", err)
		case <-time.After(20 * time.Millisecond):
		}
		if response, err := http.Get(origin + "/v1/remote/identity"); err == nil {
			response.Body.Close()
			ready = true
		}
	}
	created, err := admin("--data-dir", dir, "token", "create", "--label", "E2E", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var token struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(bytes.NewReader([]byte(created))).Decode(&token); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(map[string]string{"origin": origin, "token": token.Token})
	if err := os.WriteFile(info+".tmp", data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(info+".tmp", info); err != nil {
		t.Fatal(err)
	}
	for {
		select {
		case err := <-done:
			t.Fatal("flowd stopped:", err)
		case <-ctx.Done():
			t.Fatal("the Swift side never finished")
		case <-time.After(100 * time.Millisecond):
		}
		if _, err := os.Stat(info + ".done"); err == nil {
			cancel()
			<-done
			return
		}
	}
}
