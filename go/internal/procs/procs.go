package procs

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"time"

	"remoteagents/internal/api"
)

type manager struct {
	log    api.Logger
	tr     api.Traces
	mu     sync.Mutex
	procs  map[int]*proc
	closed bool
}

type proc struct {
	cmd *exec.Cmd
	platformProcess
	started  time.Time
	done     chan struct{}
	mu       sync.Mutex
	exited   bool
	exitCode int
	stopOnce sync.Once
	streams  []io.Closer
}

// New creates a manager; every child gets its own process group or Job.
func New(log api.Logger, tr api.Traces) (api.Procs, error) {
	return &manager{log: log, tr: tr, procs: make(map[int]*proc)}, nil
}

func (m *manager) Start(ctx context.Context, s api.ProcSpec) (api.Process, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return nil, fmt.Errorf("procs: manager closed")
	}
	if len(m.procs) >= 64 {
		return nil, fmt.Errorf("procs: maximum 64 processes")
	}
	path, err := exec.LookPath(s.Path)
	if err != nil {
		return nil, err
	}
	path, err = filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	var nonce [8]byte
	if _, err = rand.Read(nonce[:]); err != nil {
		return nil, err
	}
	id := s.Name + "-" + hex.EncodeToString(nonce[:])
	dir := s.Dir
	if dir == "" {
		dir = filepath.Dir(path)
	}
	if m.tr != nil {
		if err = m.tr.Intent(api.Trace{Phase: "intent", Kind: "process", ID: id,
			Instance: m.tr.Instance(), Owner: "procs", Data: map[string]string{"exe": path, "home": dir}}); err != nil {
			return nil, err
		}
	}
	handedOff := false
	defer func() {
		if !handedOff && m.tr != nil {
			_ = m.tr.Done("process", id)
		}
	}()
	// Cancellation is handled below after the child and its basket are ready.
	cmd := exec.Command(path, s.Args...) //nolint:noctx // Stop cancels the whole group/Job.
	cmd.Dir, cmd.Env, cmd.Stdin = s.Dir, s.Env, s.Stdin
	cmd.Stdout, cmd.Stderr = s.Stdout, s.Stderr
	cmd.WaitDelay = time.Second
	p := &proc{cmd: cmd, done: make(chan struct{}), exitCode: -1}
	for _, output := range []*io.Writer{&cmd.Stdout, &cmd.Stderr} {
		if *output == nil && s.Stream != "" && m.log != nil {
			*output = m.log.Writer(s.Stream, s.Name)
		}
	}
	for _, stream := range []any{cmd.Stdin, cmd.Stdout, cmd.Stderr} {
		if closer, ok := stream.(io.Closer); ok {
			p.streams = append(p.streams, closer)
		}
	}
	p.platformProcess, err = setupProcess(cmd, s)
	if err != nil {
		p.closeStreams()
		return nil, err
	}
	ready := make(chan error, 1)
	go func() {
		// Linux Pdeathsig is tied to the spawning OS thread: keep it until Wait.
		if runtime.GOOS == "linux" {
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
		}
		if startErr := cmd.Start(); startErr != nil {
			p.release()
			p.closeStreams()
			ready <- startErr
			return
		}
		p.started = time.Now().UTC()
		startErr := p.attach()
		if startErr == nil && m.tr != nil {
			startErr = m.tr.Applied("process", id, map[string]string{"exe": path, "home": dir,
				"pid": strconv.Itoa(p.PID()), "start": p.started.Format(time.RFC3339Nano)}, nil)
		}
		if startErr != nil {
			p.hardKill()
			_ = cmd.Process.Kill()
			p.closeStreams()
			_ = cmd.Wait()
			p.release()
			ready <- startErr
			return
		}
		ready <- nil
		// os/exec owns one copying goroutine per non-file output stream.
		_ = cmd.Wait()
		p.mu.Lock()
		p.hardKill() // Remove descendants left behind by the leader.
		p.release()
		p.exited = true
		p.exitCode = cmd.ProcessState.ExitCode()
		p.mu.Unlock()
		p.closeStreams()
		if m.tr != nil {
			_ = m.tr.Done("process", id)
		}
		m.mu.Lock()
		delete(m.procs, p.PID())
		m.mu.Unlock()
		close(p.done)
	}()
	if err = <-ready; err != nil {
		return nil, fmt.Errorf("procs: start: %w", err)
	}
	m.procs[p.PID()] = p
	handedOff = true
	go func() {
		select {
		case <-ctx.Done():
			_ = p.Stop(ctx)
		case <-p.done:
		}
	}()
	return p, nil
}

func (m *manager) KillAll(ctx context.Context) error {
	m.mu.Lock()
	m.closed = true
	list := make([]*proc, 0, len(m.procs))
	for _, p := range m.procs {
		list = append(list, p)
	}
	m.mu.Unlock()
	var wg sync.WaitGroup
	errs := make(chan error, len(list))
	for _, p := range list {
		wg.Add(1)
		go func() { defer wg.Done(); errs <- p.Stop(ctx) }()
	}
	wg.Wait()
	close(errs)
	var result error
	for err := range errs {
		result = errors.Join(result, err)
	}
	return result
}

func (m *manager) Close() error       { return m.KillAll(context.Background()) }
func (p *proc) PID() int              { return p.cmd.Process.Pid }
func (p *proc) Started() time.Time    { return p.started }
func (p *proc) Done() <-chan struct{} { return p.done }
func (p *proc) ExitCode() int         { p.mu.Lock(); defer p.mu.Unlock(); return p.exitCode }

func (p *proc) closeStreams() {
	for _, stream := range p.streams {
		_ = stream.Close()
	}
}

func (p *proc) Stop(ctx context.Context) error {
	select {
	case <-p.done:
		return nil
	default:
	}
	p.mu.Lock()
	if !p.exited {
		p.stopOnce.Do(p.softStop)
	}
	p.mu.Unlock()
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case <-p.done:
		return nil
	case <-ctx.Done():
	case <-timer.C:
	}
	p.mu.Lock()
	if !p.exited {
		p.hardKill()
	}
	p.mu.Unlock()
	p.closeStreams()
	select {
	case <-p.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
