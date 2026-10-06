package remote

import (
	"context"
	"sync"
)

// Watch serves handoff_watch (Feature 020): one handoff with action watch,
// answered by one list handoff_reply naming the meetings the calling device
// may import (sent by another device of the user, copy, released, done). It
// answers at once when there are some; otherwise it waits for a release or a
// finished processor run of the user that adds one, and after WatchTimeout
// answers an empty list. Closing the channel ends the wait. While it waits
// the channel's idle timer is off; the listener's pings keep it open.
func (s *Handoffs) Watch(_ context.Context, c *Conn, m Message) (Operation, error) {
	req, ok := m.(Handoff)
	if !ok || req.Action != "watch" {
		return nil, invalid("not a handoff watch")
	}
	if err := checkAccess(c); err != nil {
		return nil, err
	}
	w := &handoffWatch{
		handoffs: s, conn: c, op: req.Op, principalUser: c.Principal().UserID, device: c.Principal().DeviceID,
		expired: make(chan struct{}), stop: make(chan struct{}), done: make(chan struct{}),
	}
	w.timer = s.cfg.Clock.AfterFunc(s.cfg.WatchTimeout, func() { close(w.expired) })
	go w.run()
	return w, nil
}

type handoffWatch struct {
	handoffs              *Handoffs
	conn                  *Conn
	op                    int64
	principalUser, device int64
	timer                 Timer
	expired, stop, done   chan struct{}
	stopOnce              sync.Once
}

func (w *handoffWatch) run() {
	defer close(w.done)
	expired := false
	for {
		list, changed := w.handoffs.importable(w.principalUser, w.device)
		if len(list) > 0 || expired {
			if list == nil {
				list = []HandoffMeeting{}
			}
			err := w.conn.Send(context.Background(), HandoffReply{Op: w.op, Meetings: &list})
			code := "ok"
			if err != nil {
				code = "closed"
			}
			w.log(len(list), code)
			return
		}
		select {
		case <-changed:
		case <-w.expired:
			expired = true
		case <-w.stop:
			return
		case <-w.conn.Done():
			w.log(0, "closed")
			return
		}
	}
}

func (w *handoffWatch) log(meetings int, code string) {
	w.handoffs.cfg.Logger.Printf("remote handoff channel=%d user=%d device=%d op=%d action=watch meetings=%d code=%s",
		w.conn.ID(), w.principalUser, w.device, w.op, meetings, code)
}

// Control: a watch takes no further messages.
func (w *handoffWatch) Control(context.Context, Message) error {
	return invalid("handoff watch takes no messages")
}

func (w *handoffWatch) Audio(context.Context, []byte) error {
	return invalid("audio during a handoff watch")
}

func (w *handoffWatch) Done() <-chan struct{} { return w.done }

// Close stops the wait and returns once the watch's goroutine has ended.
func (w *handoffWatch) Close() {
	w.timer.Stop()
	w.stopOnce.Do(func() { close(w.stop) })
	<-w.done
}
