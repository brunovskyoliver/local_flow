// Package oidctest mints ID tokens with the repository's test-only RSA key
// (fixtures/remote/test-signing-key.pem, kid "localflow-test-1") and serves
// JWKS responses without a network, for tests of flowd's OIDC verifier and
// the enrollment operation. Nothing here is used by a production code path.
package oidctest

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
)

// KID is the key ID of the fixture key.
const KID = "localflow-test-1"

// FixturePath returns a file in fixtures/remote.
func FixturePath(name string) string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..", "..", "..", "..", "fixtures", "remote", name)
}

// JWKS returns fixtures/remote/test-jwks.json.
func JWKS(t testing.TB) []byte {
	t.Helper()
	body, err := os.ReadFile(FixturePath("test-jwks.json"))
	if err != nil {
		t.Fatal(err)
	}
	return body
}

var (
	keyOnce sync.Once
	key     *rsa.PrivateKey
	keyErr  error
)

// SigningKey returns the fixture's RSA private key.
func SigningKey(t testing.TB) *rsa.PrivateKey {
	t.Helper()
	keyOnce.Do(func() {
		var data []byte
		data, keyErr = os.ReadFile(FixturePath("test-signing-key.pem"))
		if keyErr != nil {
			return
		}
		block, _ := pem.Decode(data)
		var parsed any
		parsed, keyErr = x509.ParsePKCS8PrivateKey(block.Bytes)
		key, _ = parsed.(*rsa.PrivateKey)
	})
	if keyErr != nil || key == nil {
		t.Fatal("test signing key", keyErr)
	}
	return key
}

// Mint signs claims with the fixture key under the given header fields
// (alg RS256 and kid KID unless header overrides them). An alg other than
// RS256 still gets an RS256 signature, so only the header differs.
func Mint(t testing.TB, header map[string]any, claims map[string]any) string {
	t.Helper()
	h := map[string]any{"alg": "RS256", "kid": KID, "typ": "JWT"}
	for k, v := range header {
		if v == nil {
			delete(h, k)
		} else {
			h[k] = v
		}
	}
	encode := func(v any) string {
		data, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(data)
	}
	signed := encode(h) + "." + encode(claims)
	digest := sha256.Sum256([]byte(signed))
	signature, err := rsa.SignPKCS1v15(rand.Reader, SigningKey(t), crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return signed + "." + base64.RawURLEncoding.EncodeToString(signature)
}

// AppleNonce and GoogleNonce are the nonce claims the contract binds to the
// channel binding.
func AppleNonce(binding []byte) string {
	sum := sha256.Sum256([]byte(base64.RawURLEncoding.EncodeToString(binding)))
	const digits = "0123456789abcdef"
	var b strings.Builder
	for _, c := range sum {
		b.WriteByte(digits[c>>4])
		b.WriteByte(digits[c&15])
	}
	return b.String()
}

func GoogleNonce(binding []byte) string { return base64.RawURLEncoding.EncodeToString(binding) }

// Transport answers every request with Body (the fixture JWKS unless set),
// Status (200 unless set) and CacheControl, and records the requested URLs.
type Transport struct {
	mu           sync.Mutex
	Body         []byte
	Status       int
	CacheControl string
	urls         []string
}

// NewTransport serves the fixture JWKS.
func NewTransport(t testing.TB) *Transport { return &Transport{Body: JWKS(t)} }

func (tr *Transport) RoundTrip(r *http.Request) (*http.Response, error) {
	tr.mu.Lock()
	defer tr.mu.Unlock()
	tr.urls = append(tr.urls, r.URL.String())
	status := tr.Status
	if status == 0 {
		status = http.StatusOK
	}
	header := http.Header{"Content-Type": {"application/json"}}
	if tr.CacheControl != "" {
		header.Set("Cache-Control", tr.CacheControl)
	}
	return &http.Response{StatusCode: status, Header: header, Body: io.NopCloser(strings.NewReader(string(tr.Body))), Request: r}, nil
}

// Set replaces the response.
func (tr *Transport) Set(body []byte, cacheControl string) {
	tr.mu.Lock()
	defer tr.mu.Unlock()
	tr.Body, tr.CacheControl = body, cacheControl
}

// Requests returns the URLs fetched so far.
func (tr *Transport) Requests() []string {
	tr.mu.Lock()
	defer tr.mu.Unlock()
	return append([]string(nil), tr.urls...)
}

// Client is an http.Client using tr.
func (tr *Transport) Client() *http.Client { return &http.Client{Transport: tr} }
