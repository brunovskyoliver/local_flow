package rewrite

import (
	"net/http"
	"time"
)

const MaxConcurrentRequests = 2
const ProbeInterval = 5 * time.Second
const ProgressInterval = 250 * time.Millisecond

// Each response write has a deadline so a peer that stops reading cannot hold
// an admission slot indefinitely. No request waits in a work queue.
func writeEvent(w http.ResponseWriter, v any) error {
	data, err := EncodeLine(v)
	if err != nil {
		return err
	}
	controller := http.NewResponseController(w)
	_ = controller.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if _, err := w.Write(data); err != nil {
		return err
	}
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
	return nil
}
