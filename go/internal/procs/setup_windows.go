package procs

import (
	"fmt"
	"os/exec"
	"syscall"

	"github.com/kolesnikovae/go-winjob"
	"golang.org/x/sys/windows"

	"remoteagents/internal/api"
)

type platformProcess struct{ job *winjob.JobObject }

func setupProcess(cmd *exec.Cmd, s api.ProcSpec) (platformProcess, error) {
	if s.RunAs != "" {
		return platformProcess{}, fmt.Errorf("runAs is unsupported on Windows")
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NEW_PROCESS_GROUP, HideWindow: true}
	job, err := winjob.Create("", winjob.WithKillOnJobClose())
	return platformProcess{job: job}, err
}

func (p *proc) attach() error { return p.job.Assign(p.cmd.Process) }
func (p *proc) softStop() {
	_ = windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, uint32(p.PID()))
}
func (p *proc) hardKill() { _ = p.job.Terminate() }
func (p *proc) release()  { _ = p.job.Close() }
