package observability

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMetricsAllowlistAndBuckets(t *testing.T) {
	m := &Metrics{}
	_, _ = m.Write([]byte("flowd remote dictation user=123 device=456 op=1 duration_ms=600 code=ok secret=fixture-private-content"))
	_, _ = m.Write([]byte("flowd remote dictation duration_ms=100 code=busy"))
	m.SetQueue("dictation", 3)
	m.SetQueue("attacker", 100)
	w := httptest.NewRecorder()
	m.ServeHTTP(w, httptest.NewRequest("GET", "/metrics", nil))
	body := w.Body.String()
	for _, forbidden := range []string{"user=", "device=", "123", "456", "fixture-private-content", "attacker", "busy"} {
		if strings.Contains(body, forbidden) {
			t.Fatal("metric attribute leak", forbidden)
		}
	}
	for _, want := range []string{`localflow_requests_total{service="dictation"} 2`, `localflow_errors_total{service="dictation"} 1`, `localflow_queue_depth{service="dictation"} 3`, `le="500"} 1`, `le="1000"} 2`} {
		if !strings.Contains(body, want) {
			t.Fatal(want)
		}
	}
	if _, err := m.Listen("0.0.0.0:0"); err == nil {
		t.Fatal("public metrics accepted")
	}
}
