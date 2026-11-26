package procs

import (
	"os/exec"
	"syscall"

	"github.com/kolesnikovae/go-winjob"
	"golang.org/x/sys/windows"
)

type basket struct{ job *winjob.JobObject }

func newBasket(cmd *exec.Cmd) (basket, error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NEW_PROCESS_GROUP, HideWindow: true}
	job, err := winjob.Create("", winjob.WithKillOnJobClose())
	return basket{job: job}, err
}

func (b basket) add(c *exec.Cmd) error { return b.job.Assign(c.Process) }
func (b basket) close(*exec.Cmd)       { _ = b.job.Close() } // KILL_ON_JOB_CLOSE
func (b basket) soft(c *exec.Cmd) {
	_ = windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, uint32(c.Process.Pid))
}
func (b basket) kill(*exec.Cmd) { _ = b.job.Terminate() }
