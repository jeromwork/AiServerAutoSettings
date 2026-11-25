package procs

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"sync"
	"time"

	"remoteagents/internal/api"
)

type manager struct {
	log      api.Logger
	tr       api.Traces
	mu       sync.Mutex
	procs    map[int]*proc
	platform platformState
	closed   bool
}

type processIdentity struct {
	pid, ppid int
	started   time.Time
	live      bool
	status    int
}

type proc struct {
	cmd          *exec.Cmd
	pid          int
	started      time.Time
	done         chan struct{}
	mu           sync.Mutex
	retired      bool
	exitCode     int
	stopOnce     sync.Once
	killOnce     sync.Once
	streams      *procStreams
	platformKill func() error
	targets      []processIdentity
}

// New creates a new Procs manager.
func New(log api.Logger, tr api.Traces) (api.Procs, error) {
	plat, err := newPlatformState()
	if err != nil {
		return nil, fmt.Errorf("procs: platform-init-failed: %w", err)
	}
	return &manager{
		log:      log,
		tr:       tr,
		procs:    make(map[int]*proc),
		platform: plat,
	}, nil
}

func (m *manager) Start(ctx context.Context, s api.ProcSpec) (api.Process, error) {
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("procs: context-canceled: %w", err)
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return nil, fmt.Errorf("procs: closed: manager stopped")
	}
	if len(m.procs) >= 64 {
		return nil, fmt.Errorf("procs: limit: maximum 64 processes")
	}

	nonceBytes := make([]byte, 8)
	if _, err := rand.Read(nonceBytes); err != nil {
		return nil, fmt.Errorf("procs: nonce-failed: %w", err)
	}
	nonce := hex.EncodeToString(nonceBytes)
	traceID := fmt.Sprintf("%s-%s", s.Name, nonce)

	path, err := exec.LookPath(s.Path)
	if err != nil {
		return nil, fmt.Errorf("procs: executable: %w", err)
	}
	path, err = filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("procs: executable: %w", err)
	}
	dir := s.Dir
	if dir == "" {
		dir = filepath.Dir(s.Path)
	}

	if m.tr != nil {
		t := api.Trace{
			Phase:    "intent",
			Kind:     "process",
			ID:       traceID,
			Instance: m.tr.Instance(),
			Owner:    "procs",
			Data: map[string]string{
				"exe":  path,
				"home": dir,
			},
		}
		if err := m.tr.Intent(t); err != nil {
			return nil, fmt.Errorf("procs: intent-failed: %w", err)
		}
	}

	handedOff := false
	defer func() {
		if !handedOff {
			if m.tr != nil {
				_ = m.tr.Done("process", traceID)
			}
		}
	}()

	cmd := exec.CommandContext(ctx, path, s.Args...)
	cmd.WaitDelay = time.Second
	cmd.Dir = s.Dir
	if s.Env != nil {
		cmd.Env = s.Env
	}

	cmd.Stdin = s.Stdin
	var stdoutCloser, stderrCloser io.Closer
	if s.Stdout != nil {
		cmd.Stdout = s.Stdout
	} else if s.Stream != "" && m.log != nil {
		w := m.log.Writer(s.Stream, s.Name)
		cmd.Stdout = w
		stdoutCloser = w
	}

	if s.Stderr != nil {
		cmd.Stderr = s.Stderr
	} else if s.Stream != "" && m.log != nil {
		w := m.log.Writer(s.Stream, s.Name)
		cmd.Stderr = w
		stderrCloser = w
	}

	// Every non-file stream crosses an owned OS pipe. exec.Wait never waits
	// inside caller Read/Write methods; WaitDelay also bounds our output drain.
	streams, err := newProcStreams(cmd)
	if err != nil {
		if stdoutCloser != nil {
			_ = stdoutCloser.Close()
		}
		if stderrCloser != nil {
			_ = stderrCloser.Close()
		}
		return nil, fmt.Errorf("procs: io-setup-failed: %w", err)
	}
	defer func() {
		if !handedOff {
			streams.close()
			if stdoutCloser != nil {
				_ = stdoutCloser.Close()
			}
			if stderrCloser != nil {
				_ = stderrCloser.Close()
			}
		}
	}()

	p := &proc{cmd: cmd, streams: streams, done: make(chan struct{}), exitCode: -1}
	if err := m.setupCmd(cmd, s); err != nil {
		return nil, fmt.Errorf("procs: setup-failed: %w", err)
	}
	p.platformKill = cmd.Cancel
	cmd.Cancel = func() error {
		p.killTree()
		return nil
	}
	// CommandContext can call Cancel before Start returns. Keep cancellation
	// behind Job assignment, PID publication and trace registration.
	p.mu.Lock()
	if err := m.startCmd(cmd, ctx); err != nil {
		p.retired = true
		p.mu.Unlock()
		m.releaseCmd(cmd)
		return nil, fmt.Errorf("procs: start-failed: %w", err)
	}
	p.pid = cmd.Process.Pid
	fail := func(code string, err error) (api.Process, error) {
		// This child has not been published; its os.Process handle is ours.
		_ = cmd.Process.Kill()
		p.retired = true
		p.mu.Unlock()
		streams.close()
		_ = cmd.Wait()
		m.releaseCmd(cmd)
		return nil, fmt.Errorf("procs: %s: %w", code, err)
	}
	if err := m.postStart(cmd); err != nil {
		return fail("post-start-failed", err)
	}
	started, err := processStarted(ctx, cmd)
	if err != nil {
		return fail("identity-failed", err)
	}
	p.started = started
	pid := p.pid
	if m.tr != nil {
		appliedData := map[string]string{
			"exe": path, "home": dir, "pid": strconv.Itoa(pid),
			"start": started.Format(time.RFC3339Nano),
		}
		if err := m.tr.Applied("process", traceID, appliedData, nil); err != nil {
			return fail("applied-failed", err)
		}
	}
	m.publishCmd(cmd)
	streams.start()
	p.mu.Unlock()

	m.procs[pid] = p
	handedOff = true

	go func() {
		_ = waitExited(cmd)
		p.mu.Lock()
		p.cleanupExited()
		p.retired = true
		p.mu.Unlock()
		streams.closeInput()
		code := m.collectCmd(cmd)
		streams.finish(cmd.WaitDelay)
		m.mu.Lock()
		delete(m.procs, pid)
		m.mu.Unlock()

		p.mu.Lock()
		p.exitCode = code
		p.mu.Unlock()

		if stdoutCloser != nil {
			_ = stdoutCloser.Close()
		}
		if stderrCloser != nil {
			_ = stderrCloser.Close()
		}
		if m.tr != nil {
			_ = m.tr.Done("process", traceID)
		}
		close(p.done)
		m.reapLeader(cmd)
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
	m.terminatePlatform()
	return result
}

// Close releases the shared Job/group and any reserved Unix leader.
func (m *manager) Close() error { return m.KillAll(context.Background()) }

func (p *proc) PID() int {
	return p.pid
}

func (p *proc) Started() time.Time {
	return p.started
}

func (p *proc) Done() <-chan struct{} {
	return p.done
}

func (p *proc) ExitCode() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.exitCode
}

func (p *proc) Stop(ctx context.Context) error {
	p.streams.close()
	select {
	case <-p.done:
		return nil
	default:
	}

	if ctx.Err() != nil {
		p.killTree()
		return fmt.Errorf("procs: stop-canceled: %w", ctx.Err())
	}
	p.mu.Lock()
	if !p.retired {
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

	select {
	case <-p.done:
		return nil
	default:
	}

	p.killTree()

	select {
	case <-p.done:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("procs: stop-canceled: %w", ctx.Err())
	}
}

// Serialize signals with retirement so stale Process handles cannot kill siblings.
func (p *proc) killTree() {
	p.streams.close()
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.retired {
		p.killOnce.Do(p.hardKill)
	}
}

// streamPipe owns the OS pipe and closes a cancellable endpoint on Stop/ctx.
// In particular, an io.PipeReader/Writer blocked inside Read/Write must be
// closed too: closing only our OS pipe cannot interrupt that external call.
type streamPipe struct {
	child, parent *os.File
	src           io.Reader
	dst           io.Writer
	done          chan struct{}
	stop          chan struct{}
	closeOnce     sync.Once
	endpoint      io.Closer
}

func (s *streamPipe) close() {
	s.closeOnce.Do(func() {
		close(s.stop)
		_ = s.child.Close()
		_ = s.parent.Close()
		if s.endpoint != nil {
			_ = s.endpoint.Close()
		}
	})
}

// Hide optional WriterTo/ReaderFrom methods: after cancellation the pump must
// make no further calls into caller-owned streams, even after an empty Read.
type streamReader struct{ *streamPipe }

func (s streamReader) Read(b []byte) (int, error) {
	select {
	case <-s.stop:
		return 0, os.ErrClosed
	default:
		return s.src.Read(b)
	}
}

type streamWriter struct{ *streamPipe }

func (s streamWriter) Write(b []byte) (int, error) {
	select {
	case <-s.stop:
		return 0, os.ErrClosed
	default:
		return s.dst.Write(b)
	}
}

type procStreams struct {
	input   *streamPipe
	outputs []*streamPipe
}

func newProcStreams(cmd *exec.Cmd) (*procStreams, error) {
	s := &procStreams{}
	add := func(input bool, src io.Reader, dst io.Writer) (*streamPipe, error) {
		r, w, err := os.Pipe()
		if err != nil {
			return nil, err
		}
		p := &streamPipe{src: src, dst: dst, done: make(chan struct{}), stop: make(chan struct{})}
		if input {
			p.endpoint, _ = src.(io.Closer)
			p.child, p.parent, p.dst = r, w, w
			s.input = p
		} else {
			p.endpoint, _ = dst.(io.Closer)
			p.child, p.parent, p.src = w, r, r
			s.outputs = append(s.outputs, p)
		}
		return p, nil
	}
	if _, file := cmd.Stdin.(*os.File); cmd.Stdin != nil && !file {
		p, err := add(true, cmd.Stdin, nil)
		if err != nil {
			return nil, err
		}
		cmd.Stdin = p.child
	}
	stdout := cmd.Stdout
	// Like os/exec, serialize stdout/stderr when they are the same Writer.
	sameOutput := stdout != nil && reflect.ValueOf(stdout).Comparable() && stdout == cmd.Stderr
	for i, dst := range []*io.Writer{&cmd.Stdout, &cmd.Stderr} {
		if i == 1 && sameOutput {
			cmd.Stderr = cmd.Stdout
			continue
		}
		if _, file := (*dst).(*os.File); *dst == nil || file {
			continue
		}
		p, err := add(false, nil, *dst)
		if err != nil {
			s.close()
			return nil, err
		}
		*dst = p.child
	}
	return s, nil
}

func (s *procStreams) start() {
	pipes := append([]*streamPipe{}, s.outputs...)
	if s.input != nil {
		pipes = append(pipes, s.input)
	}
	for _, p := range pipes {
		_ = p.child.Close() // Start duplicated it into the child.
		go func() {
			defer close(p.done)
			defer func() { _ = p.parent.Close() }()
			_, _ = io.Copy(streamWriter{p}, streamReader{p})
		}()
	}
}

func (s *procStreams) closeInput() {
	if s.input != nil {
		s.input.close()
	}
}

func (s *procStreams) close() {
	s.closeInput()
	for _, p := range s.outputs {
		p.close()
	}
}

func (s *procStreams) finish(delay time.Duration) {
	defer s.close()
	timer := time.NewTimer(delay)
	defer timer.Stop()
	for _, p := range s.outputs {
		select {
		case <-p.done:
		case <-timer.C:
			return
		}
	}
}
