//go:build linux || darwin

package procs

import (
	"os/exec"
	"syscall"
)

type basket struct{}

func newBasket(cmd *exec.Cmd) (basket, error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	setDeathSignal(cmd.SysProcAttr)
	return basket{}, nil
}

func (basket) add(*exec.Cmd) error { return nil }
func (basket) close(c *exec.Cmd)   { _ = syscall.Kill(-c.Process.Pid, syscall.SIGKILL) } // leftovers of the group
func (basket) soft(c *exec.Cmd)    { _ = syscall.Kill(-c.Process.Pid, syscall.SIGTERM) }
func (basket) kill(c *exec.Cmd)    { _ = syscall.Kill(-c.Process.Pid, syscall.SIGKILL) }
