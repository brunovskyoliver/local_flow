package remote

import (
	"context"
	"log"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"localflow/server/internal/speech"
)

// MeetingWorker runs meeting jobs on the meeting worker (*speech.Supervisor
// started with Meeting set).
type MeetingWorker interface {
	Meeting(ctx context.Context, j speech.MeetingJob) (speech.MeetingResult, error)
	MeetingModels() (speech.MeetingModels, bool)
	State() speech.State
}

// meetingKinds are the job kinds a ready meeting worker serves, sorted.
var meetingKinds = []string{"diarize", "embed", "transcribe"}

// MeetingCapabilities reports ready.capabilities' meeting_jobs and models
// from the worker's current state: every kind and its models while it is
// ready, none otherwise.
func MeetingCapabilities(w MeetingWorker) func() ([]string, *CapabilityModels) {
	return func() ([]string, *CapabilityModels) {
		models, ok := w.MeetingModels()
		if !ok {
			return []string{}, nil
		}
		return append([]string{}, meetingKinds...), &CapabilityModels{
			Transcription: wireModel(*models.Transcription), Diarization: wireModel(*models.Diarization), Voice: wireModel(*models.Voice),
		}
	}
}

func wireModel(m speech.MeetingModel) *MeetingModel {
	return &MeetingModel{Engine: m.Engine, ModelID: m.ModelID, ModelRevision: m.ModelRevision, ManifestHash: m.ManifestHash, Dimension: m.Dimension}
}

// MeetingConfig configures the meeting_job operation.
type MeetingConfig struct {
	Worker MeetingWorker
	// Queue admits the jobs: per-user and global bounds, round robin, and
	// no start while a dictation or rewrite is in flight.
	Queue  *speech.MeetingQueue
	Clock  Clock
	Logger *log.Logger
}

// Meeting runs meeting_job operations (Feature 018): final transcription,
// diarization and voice embeddings on the meeting worker.
type Meeting struct {
	cfg      MeetingConfig
	buffered atomic.Int64 // sample bytes held by meeting jobs (tests)
}

// NewMeeting builds the operation; register Start under "meeting_job".
func NewMeeting(cfg MeetingConfig) *Meeting {
	if cfg.Clock == nil {
		cfg.Clock = SystemClock
	}
	if cfg.Logger == nil {
		cfg.Logger = log.New(discard{}, "", 0)
	}
	return &Meeting{cfg: cfg}
}

// Start takes a queue place for a meeting_job and begins collecting its
// samples. A worker that reported missing models offers no job kinds
// (not_offered); one that is starting or restarting is worker_unavailable.
func (mt *Meeting) Start(_ context.Context, c *Conn, m Message) (Operation, error) {
	start, ok := m.(MeetingJob)
	if !ok {
		return nil, invalid("not a meeting_job")
	}
	if err := checkAccess(c); err != nil {
		return nil, err
	}
	principal := c.Principal()
	refuse := func(code ErrorCode, reason string) (Operation, error) {
		mt.cfg.Logger.Printf("remote meeting channel=%d user=%d device=%d op=%d kind=%s queue_depth=%d code=%s",
			c.ID(), principal.UserID, principal.DeviceID, start.Op, start.Kind, mt.cfg.Queue.Waiting(), code)
		return nil, &Error{code, reason}
	}
	switch state := mt.cfg.Worker.State(); {
	case state == speech.StateUnavailable || state == speech.StateStopped:
		return refuse(CodeNotOffered, "meeting job kind not offered")
	case state != speech.StateReady:
		return refuse(CodeWorkerUnavailable, "meeting worker not ready")
	}
	ticket, err := mt.cfg.Queue.Enqueue(principal.UserID)
	if err != nil {
		return refuse(CodeBusy, "meeting job per-user bound")
	}
	ctx, cancel := context.WithCancel(context.Background())
	o := &meetingOp{mt: mt, conn: c, op: start.Op, user: principal.UserID, device: principal.DeviceID, ticket: ticket,
		job: speech.MeetingJob{Kind: start.Kind, Language: start.Language, VocabularyTerms: start.VocabularyTerms,
			Pipeline: start.Pipeline, NumSpeakers: start.NumSpeakers, Samples: make([]byte, 0, 2*start.SampleCount)},
		count: start.SampleCount, ctx: ctx, cancel: cancel, done: make(chan struct{}), started: mt.cfg.Clock.Now()}
	if o.job.Kind == "transcribe" && o.job.Language == "" {
		o.job.Language = "auto"
	}
	mt.buffered.Add(int64(2 * start.SampleCount))
	return o, nil
}

// meetingOp is one meeting job: collecting its samples, waiting in the
// queue, then running. Messages are sent under mu, so nothing follows the
// terminal one. The samples are deleted when it ends for any reason.
type meetingOp struct {
	mt      *Meeting
	conn    *Conn
	op      int64
	user    int64
	device  int64
	ticket  *speech.MeetingTicket
	count   int
	ctx     context.Context
	cancel  context.CancelFunc
	done    chan struct{}
	started time.Time

	mu         sync.Mutex
	job        speech.MeetingJob // Samples is nil once ended
	submitted  bool
	ended      bool
	resultSize int // bytes of a refused worker result, for the log
}

// endLocked deletes the samples, frees the queue place and closes done once,
// logging kind, duration and queue depth only; it reports whether this call
// ended the operation.
func (o *meetingOp) endLocked(code string) bool {
	if o.ended {
		return false
	}
	o.ended = true
	o.job.Samples = nil
	o.mt.buffered.Add(-int64(2 * o.count))
	o.ticket.Done()
	close(o.done)
	extra := ""
	if o.resultSize > 0 {
		extra = " result_bytes=" + strconv.Itoa(o.resultSize)
	}
	o.mt.cfg.Logger.Printf("remote meeting channel=%d user=%d device=%d op=%d kind=%s duration_ms=%d queue_depth=%d code=%s%s",
		o.conn.ID(), o.user, o.device, o.op, o.job.Kind, o.mt.cfg.Clock.Now().Sub(o.started).Milliseconds(), o.mt.cfg.Queue.Waiting(), code, extra)
	return true
}

func (o *meetingOp) refuseLocked(reason string) error {
	o.endLocked(string(CodeInvalidMessage))
	return invalid(reason)
}

func (o *meetingOp) Samples(_ context.Context, payload []byte) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	switch {
	case o.ended:
		return nil
	case o.submitted || len(o.job.Samples)+len(payload) > 2*o.count:
		return o.refuseLocked("more samples than sample_count")
	}
	o.job.Samples = append(o.job.Samples, payload...)
	if len(o.job.Samples) == 2*o.count {
		o.submitted = true
		go o.run(o.ticket.Submit(), o.job)
	}
	return nil
}

// send writes m unless the operation has ended.
func (o *meetingOp) send(m Message) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.ended {
		return false
	}
	if err := o.conn.Send(context.Background(), m); err != nil {
		o.endLocked("closed")
		return false
	}
	return true
}

func (o *meetingOp) run(position int, job speech.MeetingJob) {
	defer o.cancel()
	select {
	case <-o.ticket.Started():
	default:
		if !o.send(MeetingProgress{Op: o.op, State: "queued", Position: &position}) {
			return
		}
		select {
		case <-o.ticket.Started():
		case <-o.ctx.Done():
			return
		}
	}
	if !o.send(MeetingProgress{Op: o.op, State: "running"}) {
		return
	}
	result, err := o.mt.cfg.Worker.Meeting(o.ctx, job)
	job.Samples = nil
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.ended {
		return
	}
	var message Message = NewError(o.op, speechCode(err))
	if err == nil {
		m := MeetingResult{Op: o.op, Kind: job.Kind, Result: result.Result, ProcessingMS: int64(result.ProcessingMS), Model: *wireModel(result.Model)}
		// ponytail: a result must fit one control message (65,536 bytes);
		// fragment it like analysis events if long windows outgrow that.
		if _, encodeErr := EncodeMessage(m); encodeErr != nil {
			o.resultSize = len(result.Result)
			message = NewError(o.op, CodeInternal)
		} else {
			message = m
		}
	}
	code := "ok"
	if e, failed := message.(ErrorMessage); failed {
		code = string(e.Code)
	}
	o.endLocked(code)
	_ = o.conn.Send(context.Background(), message)
}

func (o *meetingOp) Done() <-chan struct{} { return o.done }

// Control: meeting_cancel stops the job at any stage and is answered
// cancelled; a job already at the worker runs on there, its result dropped.
func (o *meetingOp) Control(_ context.Context, m Message) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.ended {
		return nil
	}
	if _, ok := m.(MeetingCancel); ok {
		o.cancel()
		o.endLocked("cancelled")
		_ = o.conn.Send(context.Background(), Cancelled{Op: o.op})
		return nil
	}
	return o.refuseLocked("unexpected message during a meeting job")
}

func (o *meetingOp) Audio(context.Context, []byte) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.ended {
		return nil
	}
	return o.refuseLocked("f32le audio during a meeting job")
}

// Close cancels the job and deletes its samples.
func (o *meetingOp) Close() {
	o.cancel()
	o.mu.Lock()
	o.endLocked("closed")
	o.mu.Unlock()
}
