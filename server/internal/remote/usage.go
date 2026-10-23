package remote

import (
	"context"
	"encoding/json"
	"localflow/server/internal/usage"
	"sync"
	"time"
)

// Usage carries a strictly validated content-free request on the existing
// authenticated HPKE channel. UsageReply is its only terminal response.
type Usage struct {
	Op      int64           `json:"op"`
	Request json.RawMessage `json:"request"`
}
type UsageReply struct {
	Op       int64          `json:"op"`
	Response usage.Response `json:"response"`
}

func (Usage) MessageType() string      { return "usage" }
func (UsageReply) MessageType() string { return "usage_reply" }
func (m Usage) OpNumber() int64        { return m.Op }
func (m UsageReply) OpNumber() int64   { return m.Op }
func (m Usage) validate() (Message, error) {
	if _, err := usage.Decode(m.Request); err != nil {
		return nil, invalid("usage request")
	}
	return m, nil
}
func (m UsageReply) validate() (Message, error) {
	if m.Response.Version != 1 || len(m.Response.Rows) > 100 {
		return nil, invalid("usage response")
	}
	return m, nil
}

type UsageHandler struct {
	Store   *usage.Store
	mu      sync.Mutex
	devices map[int64]bool
}

func (h *UsageHandler) Start(ctx context.Context, c *Conn, m Message) (Operation, error) {
	req, ok := m.(Usage)
	if !ok {
		return nil, invalid("expected usage")
	}
	if !c.Now().Before(c.AccessExpiresAt()) {
		return nil, &Error{CodeTokenExpired, "expired usage session"}
	}
	p := c.Principal()
	if !c.listener.cfg.Accounts.Snapshot().Approved(p.UserID, p.DeviceID) {
		return nil, &Error{CodeRevoked, "usage approval lost"}
	}
	h.mu.Lock()
	if h.devices == nil {
		h.devices = map[int64]bool{}
	}
	if len(h.devices) >= 4 || h.devices[p.DeviceID] {
		h.mu.Unlock()
		return nil, &Error{CodeBusy, "usage admission"}
	}
	h.devices[p.DeviceID] = true
	h.mu.Unlock()
	defer func() { h.mu.Lock(); delete(h.devices, p.DeviceID); h.mu.Unlock() }()
	r, err := usage.Decode(req.Request)
	if err != nil {
		return nil, invalid("usage request")
	}
	deadline, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	result, err := h.Store.Handle(deadline, usage.Identity{User: p.UserID, Device: p.DeviceID}, r)
	if err != nil {
		return nil, &Error{CodeBusy, "usage persistence unavailable"}
	}
	return nil, c.Send(deadline, UsageReply{Op: req.Op, Response: result})
}
