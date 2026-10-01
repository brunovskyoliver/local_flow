package speech

import (
	"errors"
	"testing"
	"time"
)

func started(t *MeetingTicket) bool {
	select {
	case <-t.Started():
		return true
	default:
		return false
	}
}

func enqueue(t *testing.T, q *MeetingQueue, user int64) *MeetingTicket {
	t.Helper()
	ticket, err := q.Enqueue(user)
	if err != nil {
		t.Fatalf("user %d: %v", user, err)
	}
	ticket.Submit()
	return ticket
}

// expectStarted checks exactly which tickets are running.
func expectStarted(t *testing.T, want map[*MeetingTicket]bool) {
	t.Helper()
	for ticket, run := range want {
		if started(ticket) != run {
			t.Fatalf("ticket of user %d started=%v, want %v", ticket.user, !run, run)
		}
	}
}

// Per user: 1 running and 2 waiting; a fourth job is busy. A job still
// collecting its samples holds its waiting place but cannot start.
func TestMeetingQueuePerUser(t *testing.T) {
	q := NewMeetingQueue(nil)
	a := enqueue(t, q, 1)
	b := enqueue(t, q, 1)
	c, err := q.Enqueue(1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := q.Enqueue(1); !errors.Is(err, ErrBusy) {
		t.Fatal(err)
	}
	expectStarted(t, map[*MeetingTicket]bool{a: true, b: false, c: false})
	if position := c.Submit(); position != 1 {
		t.Fatal(position)
	}
	a.Done()
	expectStarted(t, map[*MeetingTicket]bool{b: true, c: false})
	d := enqueue(t, q, 1)
	b.Done()
	expectStarted(t, map[*MeetingTicket]bool{c: true, d: false})
	c.Done()
	d.Done()
	if q.Waiting() != 0 || q.Running() != 0 {
		t.Fatal(q.Waiting(), q.Running())
	}
}

// At most 4 jobs run across users; the rest are served round robin by user,
// so a user's second waiting job does not pass other users' first ones.
func TestMeetingQueueGlobalRoundRobin(t *testing.T) {
	q := NewMeetingQueue(nil)
	running := []*MeetingTicket{enqueue(t, q, 1), enqueue(t, q, 2), enqueue(t, q, 3), enqueue(t, q, 4)}
	a5, b5, a6, a7 := enqueue(t, q, 5), enqueue(t, q, 5), enqueue(t, q, 6), enqueue(t, q, 7)
	if q.Running() != MaxMeetingRunning || q.Waiting() != 4 {
		t.Fatal(q.Running(), q.Waiting())
	}
	running[0].Done()
	expectStarted(t, map[*MeetingTicket]bool{a5: true, b5: false, a6: false, a7: false})
	a5.Done()
	expectStarted(t, map[*MeetingTicket]bool{b5: false, a6: true, a7: false})
	running[1].Done()
	expectStarted(t, map[*MeetingTicket]bool{b5: false, a7: true})
	running[2].Done()
	expectStarted(t, map[*MeetingTicket]bool{b5: true})
}

// A job starts only while no dictation and no rewrite is in flight; once
// started it runs to completion.
func TestMeetingQueueWaitsForInteractiveWork(t *testing.T) {
	q := NewMeetingQueue(nil)
	select {
	case <-q.InteractiveIdle():
	default:
		t.Fatal("idle queue not idle")
	}
	dictation := q.BeginInteractive()
	rewrite := q.BeginInteractive()
	a := enqueue(t, q, 1)
	idle := q.InteractiveIdle()
	dictation()
	expectStarted(t, map[*MeetingTicket]bool{a: false})
	rewrite()
	rewrite() // a second call does nothing
	expectStarted(t, map[*MeetingTicket]bool{a: true})
	select {
	case <-idle:
	case <-time.After(time.Second):
		t.Fatal("idle not signalled")
	}
	q.BeginInteractive()
	expectStarted(t, map[*MeetingTicket]bool{a: true})
	b := enqueue(t, q, 2)
	expectStarted(t, map[*MeetingTicket]bool{b: false})
}

// Cancelling a waiting job removes it from the queue and frees its place.
func TestMeetingQueueCancelWaiting(t *testing.T) {
	q := NewMeetingQueue(nil)
	a, b, c := enqueue(t, q, 1), enqueue(t, q, 1), enqueue(t, q, 1)
	b.Done()
	b.Done()
	if q.Waiting() != 1 {
		t.Fatal(q.Waiting())
	}
	d := enqueue(t, q, 1)
	a.Done()
	expectStarted(t, map[*MeetingTicket]bool{b: false, c: true, d: false})
	select {
	case <-b.Started():
		t.Fatal("cancelled job started")
	default:
	}
	// A collecting job that is cancelled frees its place too.
	e, err := q.Enqueue(2)
	if err != nil {
		t.Fatal(err)
	}
	e.Done()
	if q.Waiting() != 1 {
		t.Fatal(q.Waiting())
	}
}
