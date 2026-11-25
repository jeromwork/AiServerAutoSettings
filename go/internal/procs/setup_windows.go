//go:build windows

package procs

import (
	"os/exec"
	"strconv"
	"syscall"

	"github.com/kolesnikovae/go-winjob"
	"golang.org/x/sys/windows"

	"remoteagents/internal/api"
)

type platformState struct {
	job *winjob.JobObject
}

func newPlatformState() (platformState, error) {
	job, err := winjob.Create("", winjob.WithKillOnJobClose())
	if err != nil {
		return platformState{}, err
	}
	return platformState{job: job}, nil
}

func (m *manager) terminatePlatform() {
	if m.platform.job != nil {
		_ = m.platform.job.Terminate()
	}
}

func (m *manager) setupCmd(cmd *exec.Cmd, _ api.ProcSpec) error {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.CreationFlags |= windows.CREATE_NEW_PROCESS_GROUP
	return nil
}

func (m *manager) startCmd(cmd *exec.Cmd) error {
	return cmd.Start()
}

func (m *manager) postStart(cmd *exec.Cmd) error {
	if m.platform.job != nil && cmd.Process != nil {
		return m.platform.job.Assign(cmd.Process)
	}
	return nil
}

func (p *proc) softStop() {
	if p.pid > 0 {
		_ = windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, uint32(p.pid))
	}
}

func (p *proc) hardKill() {
	if p.pid > 0 {
		killCmd := exec.Command("taskkill", "/F", "/T", "/PID", strconv.Itoa(p.pid))
		_ = killCmd.Run()
	}
	if p.cmd != nil && p.cmd.Process != nil {
		_ = p.cmd.Process.Kill()
	}
}
