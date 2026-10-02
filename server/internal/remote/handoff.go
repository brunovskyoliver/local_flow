package remote

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Meeting handoff limits.
const (
	MaxHandoffMeetings  = 16
	MaxHandoffUserBytes = 8 << 30
	HandoffTimeout      = 3 * time.Hour
	HandoffRetention    = 7 * 24 * time.Hour
)

// HandoffConfig configures meeting handoff: uploaded meetings live in
// Dir/<user id>/<MEETING-UUID>/ and the processor runs as
// `Processor --bundle <meeting dir> --meeting <UUID> Args...`.
type HandoffConfig struct {
	Dir       string
	Processor string
	Args      []string
	Env       []string
	Timeout   time.Duration // HandoffTimeout when zero
	Clock     Clock
	Logger    *log.Logger
}

// Handoffs serves the handoff operation and runs the processor on queued
// meetings, one at a time. A meeting's state is the one-word first line of
// <dir>/state (a failed meeting's detail is the second), so it survives
// restarts.
type Handoffs struct {
	cfg  HandoffConfig
	wake chan struct{}

	// ponytail: one lock over all handoff storage, so a put's final hash of
	// up to 1 GiB stalls other handoff ops for seconds; lock per meeting if
	// that matters.
	mu      sync.Mutex
	running string             // meeting dir being processed
	cancel  context.CancelFunc // stops the running processor
	hashes  map[string]string  // meeting dir -> sha256 of its done bundle
}

// NewHandoffs builds the operation; register Start under "handoff" and run Run.
func NewHandoffs(cfg HandoffConfig) *Handoffs {
	if cfg.Timeout == 0 {
		cfg.Timeout = HandoffTimeout
	}
	if cfg.Clock == nil {
		cfg.Clock = SystemClock
	}
	if cfg.Logger == nil {
		cfg.Logger = log.New(discard{}, "", 0)
	}
	return &Handoffs{cfg: cfg, wake: make(chan struct{}, 1), hashes: map[string]string{}}
}

var errHandoffStorage = &Error{CodeInternal, "handoff storage"}

// Start answers one handoff with one handoff_reply; the op then ends.
func (s *Handoffs) Start(_ context.Context, c *Conn, m Message) (Operation, error) {
	req, ok := m.(Handoff)
	if !ok {
		return nil, invalid("not a handoff")
	}
	if err := checkAccess(c); err != nil {
		return nil, err
	}
	principal := c.Principal()
	reply, err := s.handle(principal.UserID, req)
	// Puts and gets come every 48 KB; only their refusals are logged.
	if err != nil || (req.Action != "put" && req.Action != "get") {
		code := "ok"
		if err != nil {
			code = string(CodeOf(err))
		}
		s.cfg.Logger.Printf("remote handoff channel=%d user=%d device=%d op=%d action=%s meeting=%s code=%s",
			c.ID(), principal.UserID, principal.DeviceID, req.Op, req.Action, shortID(req.Meeting), code)
	}
	if err != nil {
		return nil, err
	}
	reply.Op = req.Op
	return nil, c.Send(context.Background(), reply)
}

func shortID(meeting string) string { return meeting[:min(8, len(meeting))] }

func (s *Handoffs) userDir(user int64) string {
	return filepath.Join(s.cfg.Dir, strconv.FormatInt(user, 10))
}

// filePath: bundle.sqlite sits in the meeting dir, audio under <UUID>/, the
// app's relative paths with the meeting dir as storage root.
func filePath(dir, meeting, name string) string {
	if name == "bundle.sqlite" {
		return filepath.Join(dir, name)
	}
	return filepath.Join(dir, meeting, name)
}

func readState(dir string) (state, detail string) {
	data, err := os.ReadFile(filepath.Join(dir, "state"))
	if err != nil {
		return "missing", ""
	}
	state, detail, _ = strings.Cut(strings.TrimSpace(string(data)), "\n")
	return state, detail
}

func writeState(dir, state, detail string) error {
	tmp := filepath.Join(dir, "state.tmp")
	if err := os.WriteFile(tmp, []byte(state+"\n"+detail), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, "state"))
}

func fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}

func hashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// meetings lists dir's meeting directories.
func meetings(dir string) []string {
	entries, _ := os.ReadDir(dir)
	var out []string
	for _, e := range entries {
		if e.IsDir() && validMeetingID(e.Name()) {
			out = append(out, e.Name())
		}
	}
	return out
}

func (s *Handoffs) handle(user int64, req Handoff) (HandoffReply, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	userDir := s.userDir(user)
	if req.Action == "list" {
		list := []HandoffMeeting{}
		for _, id := range meetings(userDir) {
			if state, detail := readState(filepath.Join(userDir, id)); state != "missing" && len(list) < maxHandoffList {
				list = append(list, HandoffMeeting{Meeting: id, State: state, Detail: detail})
			}
		}
		return HandoffReply{Meetings: &list}, nil
	}
	dir := filepath.Join(userDir, req.Meeting)
	state, detail := readState(dir)
	reply := HandoffReply{Meeting: req.Meeting, State: state, Detail: detail}
	switch req.Action {
	case "delete":
		if dir == s.running {
			s.cancel()
		}
		if err := os.RemoveAll(dir); err != nil {
			return reply, errHandoffStorage
		}
		delete(s.hashes, dir)
		return HandoffReply{Meeting: req.Meeting, State: "missing"}, nil
	case "put":
		if state == "missing" {
			if len(meetings(userDir)) >= MaxHandoffMeetings {
				return reply, &Error{CodeLimitExceeded, "handoff meetings per user"}
			}
			if os.MkdirAll(filepath.Join(dir, req.Meeting), 0o700) != nil || writeState(dir, "receiving", "") != nil {
				return reply, errHandoffStorage
			}
			reply.State = "receiving"
		}
		if reply.State != "receiving" {
			return reply, nil
		}
		return s.put(userDir, dir, req, reply)
	case "start":
		if state != "receiving" {
			return reply, nil
		}
		audio, _ := filepath.Glob(filepath.Join(dir, req.Meeting, "*.aac"))
		if fileSize(filepath.Join(dir, "bundle.sqlite")) == 0 || len(audio) == 0 {
			return reply, invalid("handoff upload incomplete")
		}
		if writeState(dir, "queued", "") != nil {
			return reply, errHandoffStorage
		}
		select {
		case s.wake <- struct{}{}:
		default:
		}
		reply.State = "queued"
		return reply, nil
	default: // get
		if state != "done" {
			return reply, nil
		}
		return s.get(dir, req, reply)
	}
}

// put appends data when the offset is the file's stored size and, with
// sha256, checks the whole file, emptying it on a mismatch. A put at another
// offset writes nothing, so a resent chunk cannot erase progress.
func (s *Handoffs) put(userDir, dir string, req Handoff, reply HandoffReply) (HandoffReply, error) {
	path := filePath(dir, req.Meeting, req.Name)
	size := fileSize(path)
	if *req.Offset == size {
		if len(req.Data) > 0 {
			if size+int64(len(req.Data)) > MaxHandoffFileBytes || userBytes(userDir)+int64(len(req.Data)) > MaxHandoffUserBytes {
				return reply, &Error{CodeLimitExceeded, "handoff storage bound"}
			}
			f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
			if err != nil {
				return reply, errHandoffStorage
			}
			_, err = f.Write(req.Data)
			if closeErr := f.Close(); err != nil || closeErr != nil {
				return reply, errHandoffStorage
			}
			size += int64(len(req.Data))
			now := s.cfg.Clock.Now()
			_ = os.Chtimes(dir, now, now) // the retention sweep reads the dir's time
		}
		if req.SHA256 != "" {
			if sum, err := hashFile(path); err != nil || sum != req.SHA256 {
				if os.Truncate(path, 0) != nil {
					return reply, errHandoffStorage
				}
				size = 0
			}
		}
	}
	reply.Name, reply.Offset = req.Name, &size
	return reply, nil
}

func userBytes(dir string) int64 {
	var total int64
	_ = filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if info, err := d.Info(); err == nil {
				total += info.Size()
			}
		}
		return nil
	})
	return total
}

// get returns up to MaxHandoffChunkBytes of the done bundle from offset.
func (s *Handoffs) get(dir string, req Handoff, reply HandoffReply) (HandoffReply, error) {
	path := filepath.Join(dir, "bundle.sqlite")
	f, err := os.Open(path)
	if err != nil {
		return reply, errHandoffStorage
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return reply, errHandoffStorage
	}
	size, offset := info.Size(), *req.Offset
	if offset > size {
		return reply, invalid("handoff offset past the bundle")
	}
	sum, ok := s.hashes[dir]
	if !ok {
		if sum, err = hashFile(path); err != nil {
			return reply, errHandoffStorage
		}
		s.hashes[dir] = sum
	}
	if offset < size {
		reply.Data = make([]byte, min(MaxHandoffChunkBytes, size-offset))
		if _, err := f.ReadAt(reply.Data, offset); err != nil {
			return reply, errHandoffStorage
		}
	}
	reply.Offset, reply.Size, reply.SHA256 = &offset, &size, sum
	return reply, nil
}

// Run requeues meetings left processing by a previous flowd, sweeps
// expired ones, then processes queued meetings oldest first until ctx ends,
// sweeping hourly. Ending ctx kills a running processor and leaves its
// meeting processing, to be requeued at the next start.
func (s *Handoffs) Run(ctx context.Context) {
	s.requeue()
	s.sweep()
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for ctx.Err() == nil {
		if dir, meeting, runCtx, ok := s.next(ctx); ok {
			s.process(ctx, runCtx, dir, meeting)
			continue
		}
		select {
		case <-ctx.Done():
		case <-s.wake:
		case <-ticker.C:
			s.sweep()
		}
	}
}

// each calls f for every meeting dir.
func (s *Handoffs) each(f func(dir, meeting string)) {
	users, _ := os.ReadDir(s.cfg.Dir)
	for _, user := range users {
		userDir := filepath.Join(s.cfg.Dir, user.Name())
		for _, id := range meetings(userDir) {
			f(filepath.Join(userDir, id), id)
		}
	}
}

// requeue turns processing into queued, keeping the state file's time so
// the meeting keeps its place.
func (s *Handoffs) requeue() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.each(func(dir, _ string) {
		info, err := os.Stat(filepath.Join(dir, "state"))
		if state, _ := readState(dir); err != nil || state != "processing" {
			return
		}
		if writeState(dir, "queued", "") == nil {
			_ = os.Chtimes(filepath.Join(dir, "state"), info.ModTime(), info.ModTime())
		}
	})
}

// sweep deletes meeting dirs not modified for HandoffRetention.
func (s *Handoffs) sweep() {
	s.mu.Lock()
	defer s.mu.Unlock()
	cutoff := s.cfg.Clock.Now().Add(-HandoffRetention)
	s.each(func(dir, meeting string) {
		if info, err := os.Stat(dir); err == nil && dir != s.running && info.ModTime().Before(cutoff) {
			if os.RemoveAll(dir) == nil {
				delete(s.hashes, dir)
				s.cfg.Logger.Printf("remote handoff meeting=%s event=expired", shortID(meeting))
			}
		}
	})
}

// next marks the oldest queued meeting processing and returns the context
// its processor runs under: the timeout, a delete or ctx ending stop it.
func (s *Handoffs) next(ctx context.Context) (dir, meeting string, runCtx context.Context, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var oldest time.Time
	s.each(func(d, id string) {
		info, err := os.Stat(filepath.Join(d, "state"))
		if state, _ := readState(d); err == nil && state == "queued" && (!ok || info.ModTime().Before(oldest)) {
			dir, meeting, oldest, ok = d, id, info.ModTime(), true
		}
	})
	if !ok || writeState(dir, "processing", "") != nil {
		return "", "", nil, false
	}
	s.running = dir
	runCtx, s.cancel = context.WithTimeout(ctx, s.cfg.Timeout)
	return dir, meeting, runCtx, true
}

func (s *Handoffs) process(ctx, runCtx context.Context, dir, meeting string) {
	started := s.cfg.Clock.Now()
	cmd := exec.Command(s.cfg.Processor, append([]string{"--bundle", dir, "--meeting", meeting}, s.cfg.Args...)...)
	cmd.Env = s.cfg.Env
	// Its own process group, so a kill reaches anything it started. Output
	// goes to /dev/null: it could hold meeting content.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	err := cmd.Start()
	state, detail, code := "failed", "start_failed", "start_failed"
	if err == nil {
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		select {
		case err = <-done:
		case <-runCtx.Done():
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			err = <-done
		}
		var exit *exec.ExitError
		switch {
		case ctx.Err() != nil:
			state, code = "processing", "shutdown"
		case errors.Is(runCtx.Err(), context.DeadlineExceeded):
			detail, code = "timeout", "timeout"
		case runCtx.Err() != nil:
			state, code = "missing", "deleted"
		case err == nil:
			state, detail, code = "done", "", "ok"
		case errors.As(err, &exit) && exit.ExitCode() >= 0:
			detail = "exit_" + strconv.Itoa(exit.ExitCode())
			code = detail
		default:
			detail, code = "killed", "killed"
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cancel()
	s.running, s.cancel = "", nil
	if current, _ := readState(dir); current == "processing" && state != "processing" {
		if writeState(dir, state, detail) != nil {
			code = "state_write_failed"
		}
	}
	s.cfg.Logger.Printf("remote handoff meeting=%s state=%s duration_ms=%d code=%s",
		shortID(meeting), state, s.cfg.Clock.Now().Sub(started).Milliseconds(), code)
}
