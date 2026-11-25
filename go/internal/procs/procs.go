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
	"strconv"
	"sync"
	"sync/atomic"
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

type proc struct {
	cmd      *exec.Cmd
	pid      int
	started  time.Time
	done     chan struct{}
	mu       sync.Mutex
	exitCode int
	stopOnce sync.Once
	killOnce sync.Once
	stopping atomic.Bool
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

	cmd := exec.CommandContext(ctx, path, s.Args...)
	cmd.WaitDelay = time.Second
	cmd.Dir = s.Dir
	if s.Env != nil {
		cmd.Env = s.Env
	}

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

	// os/exec accepts every io.Reader; WaitDelay bounds waiting for its pipes.
	cmd.Stdin = s.Stdin
	handedOff := false
	defer func() {
		if !handedOff {
			if m.tr != nil {
				_ = m.tr.Done("process", traceID)
			}
		}
	}()

	if err := m.setupCmd(cmd, s); err != nil {
		if stdoutCloser != nil {
			_ = stdoutCloser.Close()
		}
		if stderrCloser != nil {
			_ = stderrCloser.Close()
		}
		return nil, fmt.Errorf("procs: setup-failed: %w", err)
	}

	if err := m.startCmd(cmd, ctx); err != nil {
		m.releaseCmd(cmd)
		if stdoutCloser != nil {
			_ = stdoutCloser.Close()
		}
		if stderrCloser != nil {
			_ = stderrCloser.Close()
		}
		return nil, fmt.Errorf("procs: start-failed: %w", err)
	}

	if err := m.postStart(cmd); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		m.releaseCmd(cmd)
		if stdoutCloser != nil {
			_ = stdoutCloser.Close()
		}
		if stderrCloser != nil {
			_ = stderrCloser.Close()
		}
		return nil, fmt.Errorf("procs: post-start-failed: %w", err)
	}

	started, err := processStarted(ctx, cmd)
	if err != nil {
		p := &proc{cmd: cmd, pid: cmd.Process.Pid}
		p.killTree()
		_ = cmd.Wait()
		m.releaseCmd(cmd)
		if stdoutCloser != nil {
			_ = stdoutCloser.Close()
		}
		if stderrCloser != nil {
			_ = stderrCloser.Close()
		}
		return nil, fmt.Errorf("procs: identity-failed: %w", err)
	}
	pid := cmd.Process.Pid

	if m.tr != nil {
		appliedData := map[string]string{
			"exe":   path,
			"home":  dir,
			"pid":   strconv.Itoa(pid),
			"start": started.Format(time.RFC3339Nano),
		}
		if err := m.tr.Applied("process", traceID, appliedData, nil); err != nil {
			p := &proc{cmd: cmd, pid: pid}
			p.killTree()
			_ = cmd.Wait()
			m.releaseCmd(cmd)
			if stdoutCloser != nil {
				_ = stdoutCloser.Close()
			}
			if stderrCloser != nil {
				_ = stderrCloser.Close()
			}
			return nil, fmt.Errorf("procs: applied-failed: %w", err)
		}
	}

	p := &proc{
		cmd:      cmd,
		pid:      pid,
		started:  started,
		done:     make(chan struct{}),
		exitCode: -1,
	}

	m.procs[pid] = p
	handedOff = true

	go func() {
		err := cmd.Wait()
		// Serialize the last leader exiting with starts and other reapers, so
		// Unix descendants cannot outlive the manager's final tracked process.
		m.mu.Lock()
		p.reapExited(len(m.procs) == 1 || p.stopping.Load() || ctx.Err() != nil)
		delete(m.procs, pid)
		m.mu.Unlock()
		m.releaseCmd(cmd)

		p.mu.Lock()
		if err != nil {
			var exitErr *exec.ExitError
			if errors.As(err, &exitErr) {
				p.exitCode = exitErr.ExitCode()
			} else {
				p.exitCode = -1
			}
		} else {
			p.exitCode = 0
		}
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
	p.stopping.Store(true)
	select {
	case <-p.done:
		p.killTree()
		return nil
	default:
	}

	if ctx.Err() != nil {
		p.killTree()
		return fmt.Errorf("procs: stop-canceled: %w", ctx.Err())
	}
	p.stopOnce.Do(p.softStop)

	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()

	select {
	case <-p.done:
		p.killTree()
		return nil
	case <-ctx.Done():
	case <-timer.C:
	}

	select {
	case <-p.done:
		p.killTree()
		return nil
	default:
	}

	p.killTree()

	select {
	case <-p.done:
		p.killTree()
		return nil
	case <-ctx.Done():
		return fmt.Errorf("procs: stop-canceled: %w", ctx.Err())
	}
}

// killTree also makes repeated Stop calls safe after the original group is gone.
func (p *proc) killTree() {
	p.killOnce.Do(p.hardKill)
}
