// Package procs mirrors v2 procs.py: every child gets its own basket
// (Job Object on Windows, process group on Unix); stop = soft, 5 s, kill the whole basket.
package procs

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"sync"
	"sync/atomic"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/bus"
)

type manager struct {
	log   api.Logger
	bus   *bus.Bus
	mu    sync.Mutex
	procs map[*proc]struct{}
}

type proc struct {
	cmd     *exec.Cmd
	basket  basket
	started time.Time
	done    chan struct{}
	code    int
	name    string
	killed  atomic.Bool
}

// New creates a manager; b (may be nil) receives proc.exited events.
func New(log api.Logger, b *bus.Bus) api.Procs {
	return &manager{log: log, bus: b, procs: map[*proc]struct{}{}}
}

func (m *manager) Start(_ context.Context, s api.ProcSpec) (api.Process, error) {
	cmd := exec.Command(s.Path, s.Args...)
	cmd.Dir, cmd.Env, cmd.Stdin = s.Dir, s.Env, s.Stdin
	cmd.Stdout, cmd.Stderr = s.Stdout, s.Stderr
	var writers []io.Closer
	closeWriters := func() {
		for _, w := range writers {
			_ = w.Close()
		}
		writers = nil
	}
	// Own the output pipes: exec.Cmd.Wait must observe the parent's exit before
	// we kill its basket and join readers whose descriptors descendants may hold.
	type output struct {
		r, w *os.File
		dst  io.Writer
	}
	var outputs []output
	closePipes := func() {
		for _, o := range outputs {
			_ = o.r.Close()
			_ = o.w.Close()
		}
	}
	for _, w := range []*io.Writer{&cmd.Stdout, &cmd.Stderr} {
		if *w == nil && s.Stream != "" && m.log != nil {
			logger := m.log.Writer(s.Stream, s.Name)
			writers = append(writers, logger)
			*w = logger
		}
		if _, file := (*w).(*os.File); *w != nil && !file {
			r, pipe, err := os.Pipe()
			if err != nil {
				closePipes()
				closeWriters()
				return nil, err
			}
			outputs = append(outputs, output{r, pipe, *w})
			*w = pipe
		}
	}
	p := &proc{cmd: cmd, done: make(chan struct{}), code: -1, name: s.Name}
	var err error
	if p.basket, err = newBasket(cmd); err != nil {
		closePipes()
		closeWriters()
		return nil, err
	}
	setCmdLine(cmd, s.CmdLine)
	ready := make(chan error, 1)
	go func() {
		defer closeWriters()
		if runtime.GOOS == "linux" { // Pdeathsig is tied to the thread that started the child
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
		}
		if err := cmd.Start(); err != nil {
			closePipes()
			p.basket.close()
			ready <- err
			return
		}
		p.started = time.Now().UTC()
		var readers sync.WaitGroup
		for _, o := range outputs {
			_ = o.w.Close() // only the child keeps the write end
			readers.Add(1)
			go func() {
				defer readers.Done()
				defer o.r.Close()
				_, _ = io.Copy(o.dst, o.r)
			}()
		}
		if err := p.basket.add(cmd); err != nil {
			_ = cmd.Process.Kill()
			p.basket.kill(cmd)
			p.basket.close()
			_ = cmd.Wait()
			closePipes() // assignment failed: descendants may not belong to the basket
			readers.Wait()
			ready <- err
			return
		}
		m.mu.Lock()
		m.procs[p] = struct{}{}
		m.mu.Unlock()
		ready <- nil
		_ = cmd.Wait()
		p.code = cmd.ProcessState.ExitCode()
		p.basket.kill(cmd)
		p.basket.close()
		readers.Wait()
		closeWriters()
		m.mu.Lock()
		delete(m.procs, p)
		m.mu.Unlock()
		close(p.done)
		m.bus.Publish("proc.exited", map[string]any{"name": p.name, "code": p.code, "pid": cmd.Process.Pid, "killed": p.killed.Load()})
	}()
	if err := <-ready; err != nil {
		return nil, fmt.Errorf("procs: start: %w", err)
	}
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
	p.killed.Store(true)
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
