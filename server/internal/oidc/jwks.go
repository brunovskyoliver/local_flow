package oidc

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// JWKS bounds (research R6).
const (
	MaxJWKSBytes    = 64 << 10
	MinCache        = 5 * time.Minute
	MaxCache        = 24 * time.Hour
	RefetchInterval = time.Minute
	minRSABits      = 2048
)

// keySource resolves a JWT kid to an RS256 public key.
type keySource interface {
	key(ctx context.Context, kid string) (*rsa.PublicKey, error)
}

// remoteKeys is a provider's JWKS endpoint with a cache. Keys live for the
// response's Cache-Control max-age clamped to MinCache…MaxCache. A kid the
// cache does not hold triggers a refetch, and so does an expired cache, but
// never more than once per RefetchInterval, successful or not.
type remoteKeys struct {
	url    string
	client *http.Client
	now    func() time.Time

	mu          sync.Mutex // held across a fetch, so concurrent misses fetch once
	keys        map[string]*rsa.PublicKey
	expires     time.Time
	lastAttempt time.Time
}

func (r *remoteKeys) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	fresh := now.Before(r.expires)
	if key, ok := r.keys[kid]; ok && fresh {
		return key, nil
	}
	if !r.lastAttempt.IsZero() && now.Sub(r.lastAttempt) < RefetchInterval {
		if fresh {
			return nil, invalid("unknown kid")
		}
		return nil, ErrUnavailable
	}
	r.lastAttempt = now
	keys, lifetime, err := r.fetch(ctx)
	if err != nil {
		return nil, err
	}
	r.keys, r.expires = keys, now.Add(lifetime)
	if key, ok := keys[kid]; ok {
		return key, nil
	}
	return nil, invalid("unknown kid")
}

func (r *remoteKeys) fetch(ctx context.Context) (map[string]*rsa.PublicKey, time.Duration, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, r.url, nil)
	if err != nil {
		return nil, 0, ErrUnavailable
	}
	request.Header.Set("Accept", "application/json")
	response, err := r.client.Do(request)
	if err != nil {
		return nil, 0, ErrUnavailable
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, 0, ErrUnavailable
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, MaxJWKSBytes+1))
	if err != nil || len(body) > MaxJWKSBytes {
		return nil, 0, ErrUnavailable
	}
	keys, err := parseJWKS(body)
	if err != nil {
		return nil, 0, ErrUnavailable
	}
	return keys, cacheLifetime(response.Header.Get("Cache-Control")), nil
}

// cacheLifetime reads max-age and clamps it to MinCache…MaxCache; anything
// else (absent, no-store, malformed) gets MinCache.
func cacheLifetime(header string) time.Duration {
	lifetime := MinCache
	for _, directive := range strings.Split(header, ",") {
		name, value, _ := strings.Cut(strings.TrimSpace(directive), "=")
		if !strings.EqualFold(name, "max-age") {
			continue
		}
		seconds, err := strconv.ParseInt(strings.Trim(value, `"`), 10, 64)
		if err != nil || seconds < 0 {
			continue
		}
		lifetime = time.Duration(min(seconds, int64(MaxCache/time.Second))) * time.Second
	}
	return max(MinCache, min(lifetime, MaxCache))
}

type jwk struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Alg string `json:"alg"`
	Use string `json:"use"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// parseJWKS returns the usable RS256 signing keys of a JWKS by kid. Keys of
// another type, algorithm or use, and RSA keys under 2048 bits or with an
// unusual exponent, are skipped. A body that is not a JWKS is an error.
func parseJWKS(body []byte) (map[string]*rsa.PublicKey, error) {
	var set struct {
		Keys *[]json.RawMessage `json:"keys"`
	}
	if err := json.Unmarshal(body, &set); err != nil || set.Keys == nil {
		return nil, errors.New("oidc: not a JWKS")
	}
	keys := map[string]*rsa.PublicKey{}
	for _, raw := range *set.Keys {
		var k jwk
		if json.Unmarshal(raw, &k) != nil || k.Kty != "RSA" || k.Kid == "" ||
			(k.Alg != "" && k.Alg != "RS256") || (k.Use != "" && k.Use != "sig") {
			continue
		}
		n, errN := base64.RawURLEncoding.Strict().DecodeString(k.N)
		e, errE := base64.RawURLEncoding.Strict().DecodeString(k.E)
		if errN != nil || errE != nil || len(e) == 0 || len(e) > 4 {
			continue
		}
		modulus := new(big.Int).SetBytes(n)
		exponent := new(big.Int).SetBytes(e)
		if modulus.BitLen() < minRSABits || exponent.Int64() < 3 || exponent.Bit(0) == 0 || !exponent.IsInt64() || exponent.Int64() > 1<<31-1 {
			continue
		}
		keys[k.Kid] = &rsa.PublicKey{N: modulus, E: int(exponent.Int64())}
	}
	return keys, nil
}

// staticKeys is a fixed key set (the debug issuer's JWKS file).
type staticKeys map[string]*rsa.PublicKey

func (s staticKeys) key(_ context.Context, kid string) (*rsa.PublicKey, error) {
	if key, ok := s[kid]; ok {
		return key, nil
	}
	return nil, invalid("unknown kid")
}
