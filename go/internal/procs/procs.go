// Package procs mirrors v2 procs.py: every child gets its own basket
// (Job Object on Windows, process group on Unix); stop = soft, 5 s, kill the whole basket.
package procs

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"runtime"
	"sync"
	"time"

	"remoteagents/internal/api"
)

type manager struct {
	log   api.Logger
	mu    sync.Mutex
	procs map[*proc]struct{}
}

type proc struct {
	cmd     *exec.Cmd
	basket  basket
	started time.Time
	done    chan struct{}
	code    int
}

// New creates a manager.
func New(log api.Logger) api.Procs {
	return &manager{log: log, procs: map[*proc]struct{}{}}
}

func (m *manager) Start(_ context.Context, s api.ProcSpec) (api.Process, error) {
	if s.RunAs != "" {
		return nil, errors.New("procs: RunAs is not supported")
	}
	cmd := exec.Command(s.Path, s.Args...)
	cmd.Dir, cmd.Env, cmd.Stdin = s.Dir, s.Env, s.Stdin
	cmd.Stdout, cmd.Stderr = s.Stdout, s.Stderr
	for _, w := range []*io.Writer{&cmd.Stdout, &cmd.Stderr} {
		if *w == nil && s.Stream != "" && m.log != nil {
			*w = m.log.Writer(s.Stream, s.Name)
		}
	}
	p := &proc{cmd: cmd, done: make(chan struct{}), code: -1}
	var err error
	if p.basket, err = newBasket(cmd); err != nil {
		return nil, err
	}
	ready := make(chan error, 1)
	go func() {
		if runtime.GOOS == "linux" { // Pdeathsig is tied to the thread that started the child
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
		}
		if err := cmd.Start(); err != nil {
			p.basket.close()
			ready <- err
			return
		}
		p.started = time.Now().UTC()
		if err := p.basket.add(cmd); err != nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
			p.basket.close()
			ready <- err
			return
		}
		ready <- nil
		_ = cmd.Wait()
		p.code = cmd.ProcessState.ExitCode()
		p.basket.close()
		m.mu.Lock()
		delete(m.procs, p)
		m.mu.Unlock()
		close(p.done)
	}()
	if err := <-ready; err != nil {
		return nil, fmt.Errorf("procs: start: %w", err)
	}
	m.mu.Lock()
	m.procs[p] = struct{}{}
	m.mu.Unlock()
	return p, nil
}

func (m *manager) KillAll(ctx context.Context) error {
	m.mu.Lock()
	list := make([]*proc, 0, len(m.procs))
	for p := range m.procs {
		list = append(list, p)
	}
	m.mu.Unlock()
	errs := make([]error, len(list))
	var wg sync.WaitGroup
	for i, p := range list {
		wg.Add(1)
		go func() { defer wg.Done(); errs[i] = p.Stop(ctx) }()
	}
	wg.Wait()
	return errors.Join(errs...)
}

func (p *proc) PID() int              { return p.cmd.Process.Pid }
func (p *proc) Started() time.Time    { return p.started }
func (p *proc) Done() <-chan struct{} { return p.done }

func (p *proc) ExitCode() int {
	select {
	case <-p.done:
		return p.code
	default:
		return -1
	}
}

func (p *proc) Stop(ctx context.Context) error {
	select {
	case <-p.done:
		return nil
	default:
	}
	p.basket.soft(p.cmd)
	t := time.NewTimer(5 * time.Second)
	defer t.Stop()
	select {
	case <-p.done:
		return nil
	case <-ctx.Done():
	case <-t.C:
	}
	p.basket.kill(p.cmd)
	select {
	case <-p.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
