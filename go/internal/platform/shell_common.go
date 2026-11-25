package platform

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"sync"
	"time"

	"remoteagents/internal/api"
)

const (
	outMax  = 1 << 20 // 1 MiB buffer per stream (v2 OUT_MAX)
	execMax = 64      // 64 active procs (v2 EXEC_MAX / MAX_PROCS)
	maxWait = 25 * time.Second
)

// execProc implements api.ExecProc.
type execProc struct {
	id            string
	mu            sync.Mutex
	outBuf        []byte
	outBase       int
	errBuf        []byte
	errBase       int
	truncated     bool
	exited        bool
	code          int
	notifyCh      chan struct{}
	killFn        func() error
	killRequested bool
}

func newExecProc(id string, killFn func() error) *execProc {
	return &execProc{
		id:       id,
		code:     -1,
		notifyCh: make(chan struct{}),
		killFn:   killFn,
	}
}

func (p *execProc) ID() string {
	return p.id
}

func (p *execProc) Read(stream string, off int) api.Chunk {
	p.mu.Lock()
	defer p.mu.Unlock()

	var buf []byte
	var base int
	switch stream {
	case "out":
		buf, base = p.outBuf, p.outBase
	case "err":
		buf, base = p.errBuf, p.errBase
	default:
		return api.Chunk{NextOff: off}
	}

	offPrime := off
	if offPrime < base {
		offPrime = base
	}
	rel := offPrime - base
	if rel >= len(buf) {
		return api.Chunk{
			Data:    nil,
			NextOff: offPrime,
			Base:    base,
		}
	}

	data := buf[rel:]
	if len(data) > outMax {
		data = data[:outMax]
	}
	res := make([]byte, len(data))
	copy(res, data)

	return api.Chunk{
		Data:    res,
		NextOff: offPrime + len(res),
		Base:    base,
	}
}

func (p *execProc) WaitNew(ctx context.Context, outOff, errOff int, max time.Duration) {
	if max <= 0 || max > maxWait {
		max = maxWait
	}
	timer := time.NewTimer(max)
	defer timer.Stop()

	for {
		p.mu.Lock()
		done := p.exited ||
			outOff < p.outBase+len(p.outBuf) ||
			errOff < p.errBase+len(p.errBuf)
		changed := p.notifyCh
		p.mu.Unlock()
		if done {
			return
		}

		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			return
		case <-changed:
		}
	}
}

func (p *execProc) Exited() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.exited
}

func (p *execProc) Drained(outOff, errOff int) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.exited &&
		outOff >= p.outBase+len(p.outBuf) &&
		errOff >= p.errBase+len(p.errBuf)
}

func (p *execProc) Code() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.code
}

func (p *execProc) Truncated() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.truncated
}

func (p *execProc) Kill() error {
	p.mu.Lock()
	if p.exited {
		p.mu.Unlock()
		return nil
	}
	p.killRequested = true
	kill := p.killFn
	p.mu.Unlock()
	if kill != nil {
		return kill()
	}
	return nil
}

func (p *execProc) setKill(kill func() error) {
	p.mu.Lock()
	p.killFn = kill
	requested := p.killRequested
	p.mu.Unlock()
	if requested {
		_ = kill()
	}
}

func (p *execProc) changed() {
	close(p.notifyCh)
	p.notifyCh = make(chan struct{})
}

func (p *execProc) appendData(stream string, data []byte) {
	p.mu.Lock()
	defer p.mu.Unlock()

	var buf *[]byte
	var base *int
	switch stream {
	case "out":
		buf, base = &p.outBuf, &p.outBase
	case "err":
		buf, base = &p.errBuf, &p.errBase
	default:
		return
	}

	*buf = append(*buf, data...)
	if len(*buf) > outMax {
		cut := len(*buf) - outMax
		*base += cut
		remaining := make([]byte, outMax)
		copy(remaining, (*buf)[cut:])
		*buf = remaining
		p.truncated = true
	}

	p.changed()
}

func (p *execProc) finish(code int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.exited = true
	p.code = code

	p.changed()
}

type streamWriter struct {
	proc   *execProc
	stream string
}

func (w *streamWriter) Write(p []byte) (int, error) {
	w.proc.appendData(w.stream, p)
	return len(p), nil
}

// shellImpl implements api.Shell.
type shellImpl struct {
	log   api.Logger
	pr    api.Procs
	runAs string
	mu    sync.Mutex
	seq   uint64
	procs map[string]*execProc
	order []string
}

// NewShell creates a new api.Shell instance.
func NewShell(log api.Logger, pr api.Procs, runAs string) api.Shell {
	return &shellImpl{
		log:   log,
		pr:    pr,
		runAs: runAs,
		procs: make(map[string]*execProc),
	}
}

func (s *shellImpl) Start(ctx context.Context, r api.ExecReq) (api.ExecProc, error) {
	if r.Cmd == "" {
		return nil, errors.New("shell: empty-command: command is required")
	}

	path, args, err := buildShellCommand(r.Shell, r.Cmd)
	if err != nil {
		return nil, err
	}

	cwd := r.Cwd
	if cwd == "" {
		cwd = defaultWorkDir(s.runAs)
	}

	s.mu.Lock()
	if len(s.procs) >= execMax {
		evicted := false
		for i, id := range s.order {
			if p, ok := s.procs[id]; ok && p.Exited() {
				delete(s.procs, id)
				s.order = append(s.order[:i], s.order[i+1:]...)
				evicted = true
				break
			}
		}
		if !evicted {
			s.mu.Unlock()
			return nil, fmt.Errorf("shell: too-many-processes: maximum active processes (%d) reached", execMax)
		}
	}
	s.seq++
	id := strconv.FormatUint(s.seq, 10)
	proc := newExecProc(id, nil)
	s.procs[id] = proc
	s.order = append(s.order, id)
	s.mu.Unlock()

	if s.log != nil {
		s.log.Info("shell.start", "id", id, "shell", r.Shell, "cmd", r.Cmd, "dir", cwd)
	}

	if err := startProc(ctx, s.pr, s.runAs, path, args, cwd, r, proc); err != nil {
		s.mu.Lock()
		for i, oid := range s.order {
			if oid == id {
				s.order = append(s.order[:i], s.order[i+1:]...)
				break
			}
		}
		delete(s.procs, id)
		s.mu.Unlock()
		return nil, err
	}

	if r.Wait {
		for {
			proc.mu.Lock()
			exited, changed := proc.exited, proc.notifyCh
			proc.mu.Unlock()
			if exited {
				break
			}
			select {
			case <-ctx.Done():
				return proc, ctx.Err()
			case <-changed:
			}
		}
	}

	return proc, nil
}

func (s *shellImpl) Get(id string) (api.ExecProc, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.procs[id]
	return p, ok
}

func (s *shellImpl) List() []api.ExecProc {
	s.mu.Lock()
	defer s.mu.Unlock()
	res := make([]api.ExecProc, 0, len(s.order))
	for _, id := range s.order {
		if p, ok := s.procs[id]; ok {
			res = append(res, p)
		}
	}
	return res
}

func (s *shellImpl) KillAll() error {
	s.mu.Lock()
	procs := make([]*execProc, 0, len(s.procs))
	for _, p := range s.procs {
		procs = append(procs, p)
	}
	s.mu.Unlock()

	var firstErr error
	for _, p := range procs {
		if err := p.Kill(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}
