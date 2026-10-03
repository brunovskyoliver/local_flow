package speech

import (
	"io"
	"log"
	"sync"
)

// Meeting job bounds (Feature 018 research R7).
const (
	// MaxMeetingWaitingPerUser is the number of meeting jobs a user may have
	// waiting, besides MaxMeetingRunningPerUser running.
	MaxMeetingWaitingPerUser = 2
	MaxMeetingRunningPerUser = 1
	// MaxMeetingRunning bounds running meeting jobs across users.
	MaxMeetingRunning = 4
)

// MeetingQueue admits meeting jobs. Each user has at most
// MaxMeetingRunningPerUser running and MaxMeetingWaitingPerUser waiting jobs;
// at most MaxMeetingRunning run in all, and waiting users are served round
// robin. A job starts only while no interactive work (a dictation or a
// rewrite) is in flight, then runs to completion (principle 15: dictation,
// rewrite, then meeting work).
type MeetingQueue struct {
	logger *log.Logger

	mu          sync.Mutex
	waitingBy   map[int64]int              // waiting and collecting tickets per user
	runningBy   map[int64]int              // running tickets per user
	queues      map[int64][]*MeetingTicket // submitted tickets per user, FIFO
	ring        []int64                    // users with submitted tickets, in service order
	waiting     int                        // submitted tickets
	running     int
	interactive int
	idle        chan struct{} // closed while no interactive work is in flight
	busy        chan struct{} // closed while interactive work is in flight
}

// MeetingTicket is one job's place in the queue.
type MeetingTicket struct {
	q       *MeetingQueue
	user    int64
	started chan struct{}
	state   ticketState
}

type ticketState int

const (
	ticketCollecting ticketState = iota // holds a waiting place, not yet submitted
	ticketWaiting
	ticketRunning
	ticketDone
)

// NewMeetingQueue returns an empty queue. logger receives content-free lines.
func NewMeetingQueue(logger *log.Logger) *MeetingQueue {
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}
	idle := make(chan struct{})
	close(idle)
	return &MeetingQueue{logger: logger, waitingBy: map[int64]int{}, runningBy: map[int64]int{}, queues: map[int64][]*MeetingTicket{}, idle: idle, busy: make(chan struct{})}
}

// Enqueue takes a waiting place for a job whose samples are still arriving,
// or returns ErrBusy when the user already has MaxMeetingWaitingPerUser jobs
// waiting. Call Submit once the samples are complete and Done when the job
// ends for any reason.
func (q *MeetingQueue) Enqueue(user int64) (*MeetingTicket, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.waitingBy[user] >= MaxMeetingWaitingPerUser {
		q.logger.Printf("speech meeting_busy user=%d waiting=%d running=%d", user, q.waiting, q.running)
		return nil, ErrBusy
	}
	q.waitingBy[user]++
	return &MeetingTicket{q: q, user: user, started: make(chan struct{})}, nil
}

// Submit queues the job and returns how many jobs wait ahead of it across
// users. ponytail: the count ignores round-robin reordering, so it is an
// upper bound for users with one job and approximate otherwise.
func (t *MeetingTicket) Submit() int {
	q := t.q
	q.mu.Lock()
	defer q.mu.Unlock()
	if t.state != ticketCollecting {
		return 0
	}
	position := q.waiting
	t.state = ticketWaiting
	if len(q.queues[t.user]) == 0 {
		q.ring = append(q.ring, t.user)
	}
	q.queues[t.user] = append(q.queues[t.user], t)
	q.waiting++
	q.promoteLocked()
	return position
}

// Started is closed when the job may run.
func (t *MeetingTicket) Started() <-chan struct{} { return t.started }

// Done ends the job: a waiting one leaves the queue, a running one frees its
// slot. Calling it again does nothing.
func (t *MeetingTicket) Done() {
	q := t.q
	q.mu.Lock()
	defer q.mu.Unlock()
	switch t.state {
	case ticketCollecting:
		q.leaveWaitingLocked(t.user)
	case ticketWaiting:
		q.leaveWaitingLocked(t.user)
		q.waiting--
		kept := q.queues[t.user][:0]
		for _, other := range q.queues[t.user] {
			if other != t {
				kept = append(kept, other)
			}
		}
		if len(kept) == 0 {
			delete(q.queues, t.user)
			q.leaveRingLocked(t.user)
		} else {
			q.queues[t.user] = kept
		}
	case ticketRunning:
		q.running--
		if q.runningBy[t.user]--; q.runningBy[t.user] <= 0 {
			delete(q.runningBy, t.user)
		}
		q.promoteLocked()
	}
	t.state = ticketDone
}

func (q *MeetingQueue) leaveWaitingLocked(user int64) {
	if q.waitingBy[user]--; q.waitingBy[user] <= 0 {
		delete(q.waitingBy, user)
	}
}

func (q *MeetingQueue) leaveRingLocked(user int64) {
	for i, u := range q.ring {
		if u == user {
			q.ring = append(q.ring[:i], q.ring[i+1:]...)
			return
		}
	}
}

// promoteLocked starts waiting jobs while slots are free and no interactive
// work is in flight, taking the next user in the ring whose own running slot
// is free.
func (q *MeetingQueue) promoteLocked() {
	for q.interactive == 0 && q.running < MaxMeetingRunning {
		i := 0
		for i < len(q.ring) && q.runningBy[q.ring[i]] >= MaxMeetingRunningPerUser {
			i++
		}
		if i == len(q.ring) {
			return
		}
		user := q.ring[i]
		q.ring = append(q.ring[:i], q.ring[i+1:]...)
		t := q.queues[user][0]
		if rest := q.queues[user][1:]; len(rest) > 0 {
			q.queues[user] = rest
			q.ring = append(q.ring, user)
		} else {
			delete(q.queues, user)
		}
		q.waiting--
		q.leaveWaitingLocked(user)
		q.running++
		q.runningBy[user]++
		t.state = ticketRunning
		close(t.started)
	}
}

// BeginInteractive records interactive work in flight (a dictation or a
// rewrite); no meeting job starts until every returned end function has been
// called. Calling an end function again does nothing.
func (q *MeetingQueue) BeginInteractive() (end func()) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.interactive == 0 {
		q.idle = make(chan struct{})
		close(q.busy)
	}
	q.interactive++
	var once sync.Once
	return func() {
		once.Do(func() {
			q.mu.Lock()
			defer q.mu.Unlock()
			if q.interactive--; q.interactive == 0 {
				close(q.idle)
				q.busy = make(chan struct{})
				q.promoteLocked()
			}
		})
	}
}

// InteractiveIdle is closed while no interactive work is in flight; the
// meeting supervisor's Gate, so jobs that already started still reach the
// worker only between dictations and rewrites.
func (q *MeetingQueue) InteractiveIdle() <-chan struct{} {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.idle
}

// InteractiveBusy is closed while interactive work is in flight; meeting
// handoff pauses its processor on it and resumes on InteractiveIdle.
func (q *MeetingQueue) InteractiveBusy() <-chan struct{} {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.busy
}

// Waiting is the number of submitted jobs not yet started, across users.
func (q *MeetingQueue) Waiting() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.waiting
}

// Running is the number of started jobs not yet done.
func (q *MeetingQueue) Running() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.running
}
