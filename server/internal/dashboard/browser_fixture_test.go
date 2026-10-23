package dashboard

import (
	"context"
	"fmt"
	"localflow/server/internal/usage"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

// TestBrowserFixture is opt-in test tooling, not a production authentication
// switch. It binds loopback, uses a temporary database and expires after 10 min.
func TestBrowserFixture(t *testing.T) {
	if os.Getenv("LOCALFLOW_DASHBOARD_FIXTURE") != "1" {
		t.Skip("interactive fixture disabled")
	}
	p := fixture(t)
	h := handler(t, p)
	b := batch()
	b.Directory = &usage.Directory{Label: "Oliver (fixture)", Revision: 1}
	b.Rows[0].LocalCount = 12
	b.Rows[0].RemoteCount = 8
	b.Rows[0].LocalAudioMS = 96000
	b.Rows[0].RemoteAudioMS = 64000
	if e := p.Apply(context.Background(), b); e != nil {
		t.Fatal(e)
	}
	h.sessions["browser-fixture"] = session{time.Now().Add(time.Hour), "fixture-csrf"}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.AddCookie(&http.Cookie{Name: "__Host-localflow", Value: "browser-fixture"})
		h.ServeHTTP(w, r)
	}))
	defer srv.Close()
	fmt.Println("LOCALFLOW_BROWSER_FIXTURE=" + srv.URL)
	timer := time.NewTimer(10 * time.Minute)
	defer timer.Stop()
	<-timer.C
}
