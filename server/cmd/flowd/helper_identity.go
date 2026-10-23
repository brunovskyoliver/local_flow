package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
)

// Capture once before serving. Reading the executable after replacement would
// incorrectly identify an old running process as the new bundled helper.
func helperIdentityHandler() http.Handler {
	digest := ""
	if path, err := os.Executable(); err == nil {
		if f, err := os.Open(path); err == nil {
			h := sha256.New()
			n, err := io.Copy(h, io.LimitReader(f, (256<<20)+1))
			_ = f.Close()
			if err == nil && n <= 256<<20 {
				digest = hex.EncodeToString(h.Sum(nil))
			}
		}
	}
	return serveHelperIdentity(digest)
}

func serveHelperIdentity(digest string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || !net.ParseIP(host).IsLoopback() {
			http.NotFound(w, r)
			return
		}
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if len(digest) != 64 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(struct {
			SHA256 string `json:"sha256"`
		}{digest})
	})
}
