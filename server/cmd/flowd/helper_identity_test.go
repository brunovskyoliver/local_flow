package main

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHelperIdentityIsLoopbackOnly(t *testing.T) {
	h := serveHelperIdentity(strings.Repeat("a", 64))
	for _, tc := range []struct {
		addr string
		code int
	}{{"127.0.0.1:1234", 200}, {"[::1]:1234", 200}, {"192.0.2.1:1234", 404}, {"invalid", 404}} {
		r := httptest.NewRequest("GET", "/v1/helper/identity", nil)
		r.RemoteAddr = tc.addr
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.code {
			t.Errorf("%s: %d", tc.addr, w.Code)
		}
	}
}
func TestHelperIdentityFailsClosed(t *testing.T) {
	r := httptest.NewRequest("GET", "/v1/helper/identity", nil)
	r.RemoteAddr = "127.0.0.1:1"
	w := httptest.NewRecorder()
	serveHelperIdentity("").ServeHTTP(w, r)
	if w.Code != 503 {
		t.Fatal(w.Code)
	}
}
