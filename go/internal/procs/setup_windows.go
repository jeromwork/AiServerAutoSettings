//go:build windows

package procs

import (
	"context"
	"fmt"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/kolesnikovae/go-winjob"
	"golang.org/x/sys/windows"

	"remoteagents/internal/api"
)

type platformState struct {
	job  *winjob.JobObject
	jobs *sync.Map
}

func newPlatformState() (platformState, error) {
	job, err := winjob.Create("", winjob.WithKillOnJobClose())
	if err != nil {
		return platformState{}, err
	}
	return platformState{job: job, jobs: &sync.Map{}}, nil
}

func (m *manager) terminatePlatform() {
	if m.platform.job != nil {
		_ = m.platform.job.Terminate()
		_ = m.platform.job.Close()
	}
}

func (m *manager) setupCmd(cmd *exec.Cmd, s api.ProcSpec) error {
	if s.RunAs != "" {
		return fmt.Errorf("runAs is unsupported on Windows")
	}
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.CreationFlags |= windows.CREATE_NEW_PROCESS_GROUP
	job, err := winjob.Create("", winjob.WithKillOnJobClose())
	if err != nil {
		return err
	}
	owned := &processJob{job: job}
	m.platform.jobs.Store(cmd, owned)
	cmd.Cancel = owned.terminate
	return nil
}

type processJob struct {
	mu  sync.Mutex
	job *winjob.JobObject
}

func (j *processJob) terminate() error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.job == nil {
		return nil
	}
	return j.job.Terminate()
}

func (j *processJob) close() {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.job != nil {
		_ = j.job.Close()
		j.job = nil
	}
}

func (m *manager) startCmd(cmd *exec.Cmd, _ context.Context) error {
	return cmd.Start()
}

func (m *manager) postStart(cmd *exec.Cmd) error {
	if m.platform.job != nil && cmd.Process != nil {
		if err := m.platform.job.Assign(cmd.Process); err != nil {
			return err
		}
		if v, ok := m.platform.jobs.Load(cmd); ok {
			return v.(*processJob).job.Assign(cmd.Process)
		}
	}
	return nil
}

func (p *proc) softStop() {
	if p.pid > 0 {
		_ = windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, uint32(p.pid))
	}
}

func (p *proc) hardKill() {
	if p.cmd != nil && p.cmd.Cancel != nil {
		_ = p.cmd.Cancel()
	}
	if p.cmd != nil && p.cmd.Process != nil {
		_ = p.cmd.Process.Kill()
	}
}

func (m *manager) releaseCmd(cmd *exec.Cmd) {
	if v, ok := m.platform.jobs.LoadAndDelete(cmd); ok {
		v.(*processJob).close()
	}
}

func processStarted(_ context.Context, cmd *exec.Cmd) (time.Time, error) {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(cmd.Process.Pid))
	if err != nil {
		return time.Time{}, err
	}
	defer windows.CloseHandle(h)
	var created, exited, kernel, user windows.Filetime
	if err := windows.GetProcessTimes(h, &created, &exited, &kernel, &user); err != nil {
		return time.Time{}, err
	}
	return time.Unix(0, created.Nanoseconds()).UTC(), nil
}
