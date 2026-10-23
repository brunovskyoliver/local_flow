// Package observability exposes bounded content-free operational metrics.
package observability

import (
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

var services = []string{"dictation", "rewrite", "analysis", "meeting", "live"}
var bounds = []int64{100, 500, 1000, 3000, 10000, 60000, 600000}

type counts struct {
	total   uint64
	errors  uint64
	buckets [7]uint64
	sum     uint64
}
type Metrics struct {
	mu     sync.Mutex
	values [5]counts
	queue  [5]int64
	ready  [2]bool
}

func (m *Metrics) Write(p []byte) (int, error) {
	if len(p) > 65536 {
		return len(p), nil
	}
	line := string(p)
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, service := range services {
		if !strings.Contains(line, " remote "+service+" ") {
			continue
		}
		fields := strings.Fields(line)
		code := ""
		duration := int64(-1)
		for _, field := range fields {
			if v, ok := strings.CutPrefix(field, "code="); ok {
				code = v
			}
			if v, ok := strings.CutPrefix(field, "duration_ms="); ok {
				if n, err := strconv.ParseInt(v, 10, 64); err == nil && n >= 0 && n <= 600000 {
					duration = n
				}
			}
		}
		if code == "" {
			continue
		}
		c := &m.values[i]
		c.total++
		switch code {
		case "ok", "succeeded", "closed", "discarded", "cancelled":
		default:
			c.errors++
		}
		if duration >= 0 {
			c.sum += uint64(duration)
			for j, b := range bounds {
				if duration <= b {
					c.buckets[j]++
				}
			}
		}
	}
	if strings.Contains(line, "worker_state=") {
		kind := 0
		if strings.Contains(line, "flowd meeting ") {
			kind = 1
		}
		m.ready[kind] = strings.Contains(line, "worker_state=ready")
	}
	return len(p), nil
}
func (m *Metrics) SetQueue(service string, depth int64) {
	if depth < 0 || depth > 1024 {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, s := range services {
		if s == service {
			m.queue[i] = depth
		}
	}
}
func (m *Metrics) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" || r.URL.Path != "/metrics" {
		http.NotFound(w, r)
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	for i, s := range services {
		c := m.values[i]
		fmt.Fprintf(w, "localflow_requests_total{service=%q} %d\nlocalflow_errors_total{service=%q} %d\nlocalflow_queue_depth{service=%q} %d\n", s, c.total, s, c.errors, s, m.queue[i])
		for j, b := range bounds {
			fmt.Fprintf(w, "localflow_request_duration_milliseconds_bucket{service=%q,le=%q} %d\n", s, strconv.FormatInt(b, 10), c.buckets[j])
		}
		fmt.Fprintf(w, "localflow_request_duration_milliseconds_bucket{service=%q,le=\"+Inf\"} %d\nlocalflow_request_duration_milliseconds_count{service=%q} %d\nlocalflow_request_duration_milliseconds_sum{service=%q} %d\n", s, c.buckets[6], s, c.buckets[6], s, c.sum)
	}
	for i, kind := range []string{"speech", "meeting"} {
		v := 0
		if m.ready[i] {
			v = 1
		}
		fmt.Fprintf(w, "localflow_worker_ready{kind=%q} %d\n", kind, v)
	}
}
func (m *Metrics) Listen(address string) (func(), error) {
	if address == "" {
		return func() {}, nil
	}
	host, _, err := net.SplitHostPort(address)
	ip := net.ParseIP(host)
	if err != nil || ip == nil || !ip.IsLoopback() {
		return nil, fmt.Errorf("metrics must bind a loopback IP literal")
	}
	l, err := net.Listen("tcp", address)
	if err != nil {
		return nil, err
	}
	srv := &http.Server{Handler: m, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 10 * time.Second, MaxHeaderBytes: 4096}
	go func() { _ = srv.Serve(l) }()
	return func() { _ = srv.Close() }, nil
}
