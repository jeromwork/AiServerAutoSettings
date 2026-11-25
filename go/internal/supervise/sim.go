package supervise

import (
	"context"
	"fmt"
	"os/exec"
	"time"

	"remoteagents/internal/api"
)

// NewSimulationProcs supplies process groups for the temporary slot-script driver.
func NewSimulationProcs() api.Procs { return &simProcs{} }

type simProcs struct{}
type simProcess struct {
	cmd     *exec.Cmd
	done    chan struct{}
	started time.Time
	code    int
}

func (*simProcs) Start(ctx context.Context, spec api.ProcSpec) (api.Process, error) {
	cmd := exec.CommandContext(ctx, spec.Path, spec.Args...)
	cmd.Dir, cmd.Stdout, cmd.Stderr = spec.Dir, spec.Stdout, spec.Stderr
	cmd.WaitDelay = time.Second
	setSysProcAttr(cmd)
	cmd.Cancel = func() error { killProcessGroup(cmd); return cmd.Process.Kill() }
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	release, err := attachProcess(cmd)
	if err != nil {
		killProcessGroup(cmd)
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, err
	}
	p := &simProcess{cmd: cmd, done: make(chan struct{}), started: time.Now()}
	go func() {
		if cmd.Wait() != nil {
			p.code = 1
		}
		release()
		killProcessGroup(cmd)
		close(p.done)
	}()
	return p, nil
}
func (*simProcs) KillAll(context.Context) error { return nil }
func (p *simProcess) PID() int                  { return p.cmd.Process.Pid }
func (p *simProcess) Started() time.Time        { return p.started }
func (p *simProcess) Done() <-chan struct{}     { return p.done }
func (p *simProcess) ExitCode() int             { <-p.done; return p.code }
func (p *simProcess) Stop(ctx context.Context) error {
	select {
	case <-p.done:
		return nil
	default:
	}
	killProcessGroup(p.cmd)
	_ = p.cmd.Process.Kill()
	select {
	case <-p.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(2 * time.Second):
		return fmt.Errorf("sim: stop-timeout")
	}
}
