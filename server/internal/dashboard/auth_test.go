package dashboard

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"localflow/server/internal/oidc"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

type testVerifier struct {
	subject string
	called  bool
}

func (v *testVerifier) Verify(_ context.Context, provider, token string, binding []byte) (oidc.Identity, error) {
	v.called = true
	if provider != "google" || len(binding) != 32 {
		return oidc.Identity{}, fmt.Errorf("nonce missing")
	}
	return oidc.Identity{Provider: "google", Subject: v.subject}, nil
}

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestOwnerOIDCAllowlistAndSecureSession(t *testing.T) {
	for _, tc := range []struct {
		name, subject, issuer string
		want                  int
	}{{"owner", "owner", "https://accounts.google.com", 303}, {"other subject", "other", "https://accounts.google.com", 403}, {"legacy issuer rejected", "owner", "accounts.google.com", 403}} {
		t.Run(tc.name, func(t *testing.T) {
			p := fixture(t)
			v := &testVerifier{subject: tc.subject}
			idToken := "header." + base64.RawURLEncoding.EncodeToString([]byte(`{"iss":"`+tc.issuer+`"}`)) + ".signature"
			client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
				if r.URL.String() != "https://oauth2.googleapis.com/token" {
					t.Fatal(r.URL)
				}
				if e := r.ParseForm(); e != nil || r.Form.Get("code_verifier") == "" || r.Form.Get("grant_type") != "authorization_code" {
					t.Fatal("PKCE missing")
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"id_token":"` + idToken + `"}`)), Header: http.Header{}}, nil
			})}
			h, e := New(p, Config{BaseURL: "https://dashboard.example", OwnerIssuer: "https://accounts.google.com", OwnerSubject: "owner", ClientID: "client", ClientSecret: "secret", Installation: installation, IngestCredential: credential, Verifier: v, HTTPClient: client})
			if e != nil {
				t.Fatal(e)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, httptest.NewRequest("GET", "/login", nil))
			location, _ := url.Parse(w.Header().Get("Location"))
			if location.Query().Get("code_challenge_method") != "S256" || location.Query().Get("nonce") == "" {
				t.Fatal(location)
			}
			cookies := w.Result().Cookies()
			if len(cookies) != 1 || !cookies[0].Secure || !cookies[0].HttpOnly {
				t.Fatal(cookies)
			}
			r := httptest.NewRequest("GET", "/callback?state="+url.QueryEscape(location.Query().Get("state"))+"&code=fixture", nil)
			r.AddCookie(cookies[0])
			w = httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.want || !v.called {
				t.Fatal(w.Code, v.called)
			}
			if tc.want == 303 {
				sessionCookies := w.Result().Cookies()
				if len(sessionCookies) != 2 || !sessionCookies[0].Secure || !sessionCookies[0].HttpOnly || sessionCookies[0].SameSite != http.SameSiteLaxMode || sessionCookies[0].MaxAge != 28800 {
					t.Fatal(sessionCookies)
				}
			}
			// OAuth state is consumed even when authorization fails.
			w = httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != 403 {
				t.Fatal("state replay accepted", w.Code)
			}
		})
	}
}
func TestExpiredSessionsAndBoundedPendingLogins(t *testing.T) {
	p := fixture(t)
	h := handler(t, p)
	h.sessions["old"] = session{time.Now().Add(-time.Second), "csrf"}
	r := httptest.NewRequest("GET", "/", nil)
	r.AddCookie(&http.Cookie{Name: "__Host-localflow", Value: "old"})
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 303 {
		t.Fatal(w.Code)
	}
	for i := 0; i < 11; i++ {
		w = httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", "/login", nil))
		want := 302
		if i == 10 {
			want = 503
		}
		if w.Code != want {
			t.Fatal(i, w.Code)
		}
	}
	if len(h.logins) != 10 {
		t.Fatal(len(h.logins))
	}
}
