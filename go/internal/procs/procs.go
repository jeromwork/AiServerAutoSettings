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
	"time"

	"remoteagents/internal/api"
)

type manager struct {
	log      api.Logger
	tr       api.Traces
	mu       sync.Mutex
	procs    map[int]*proc
	platform platformState
}

type proc struct {
	cmd      *exec.Cmd
	pid      int
	started  time.Time
	done     chan struct{}
	mu       sync.Mutex
	exitCode int
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

	nonceBytes := make([]byte, 8)
	if _, err := rand.Read(nonceBytes); err != nil {
		return nil, fmt.Errorf("procs: nonce-failed: %w", err)
	}
	nonce := hex.EncodeToString(nonceBytes)
	traceID := fmt.Sprintf("%s-%s", s.Name, nonce)

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
				"exe":  s.Path,
				"home": dir,
			},
		}
		if err := m.tr.Intent(t); err != nil {
			return nil, fmt.Errorf("procs: intent-failed: %w", err)
		}
	}

	cmd := exec.Command(s.Path, s.Args...)
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

	if s.Stdin != nil {
		cmd.Stdin = s.Stdin
	}

	if err := m.setupCmd(cmd, s); err != nil {
		if stdoutCloser != nil {
			_ = stdoutCloser.Close()
		}
		if stderrCloser != nil {
			_ = stderrCloser.Close()
		}
		if m.tr != nil {
			_ = m.tr.Done("process", traceID)
		}
		return nil, fmt.Errorf("procs: setup-failed: %w", err)
	}

	if err := m.startCmd(cmd); err != nil {
		if stdoutCloser != nil {
			_ = stdoutCloser.Close()
		}
		if stderrCloser != nil {
			_ = stderrCloser.Close()
		}
		if m.tr != nil {
			_ = m.tr.Done("process", traceID)
		}
		return nil, fmt.Errorf("procs: start-failed: %w", err)
	}

	if err := m.postStart(cmd); err != nil && m.log != nil {
		m.log.Warn("procs: post-start-failed", "err", err.Error())
	}

	started := time.Now().UTC()
	pid := cmd.Process.Pid

	if m.tr != nil {
		appliedData := map[string]string{
			"exe":   s.Path,
			"home":  dir,
			"pid":   strconv.Itoa(pid),
			"start": started.Format(time.RFC3339Nano),
		}
		_ = m.tr.Applied("process", traceID, appliedData, nil)
	}

	p := &proc{
		cmd:      cmd,
		pid:      pid,
		started:  started,
		done:     make(chan struct{}),
		exitCode: -1,
	}

	m.mu.Lock()
	m.procs[pid] = p
	m.mu.Unlock()

	go func() {
		err := cmd.Wait()

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
		m.mu.Lock()
		delete(m.procs, pid)
		m.mu.Unlock()
		close(p.done)
	}()

	return p, nil
}

func (m *manager) KillAll(ctx context.Context) error {
	m.terminatePlatform()

	m.mu.Lock()
	procsList := make([]*proc, 0, len(m.procs))
	for _, p := range m.procs {
		procsList = append(procsList, p)
	}
	m.mu.Unlock()

	var wg sync.WaitGroup
	for _, p := range procsList {
		wg.Add(1)
		go func(pr *proc) {
			defer wg.Done()
			_ = pr.Stop(ctx)
		}(p)
	}

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("procs: kill-all-canceled: %w", ctx.Err())
	}
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
	select {
	case <-p.done:
		return nil
	default:
	}

	p.softStop()

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

	p.hardKill()

	select {
	case <-p.done:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("procs: stop-canceled: %w", ctx.Err())
	}
}
