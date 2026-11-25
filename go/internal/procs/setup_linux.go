//go:build linux

package procs

import (
	"os"
	"os/exec"
	"os/user"
	"runtime"
	"strconv"
	"syscall"

	"remoteagents/internal/api"
)

type platformState struct{}

func newPlatformState() (platformState, error) {
	return platformState{}, nil
}

func (m *manager) terminatePlatform() {}

func (m *manager) setupCmd(cmd *exec.Cmd, s api.ProcSpec) error {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
	cmd.SysProcAttr.Pdeathsig = syscall.SIGKILL

	if s.RunAs != "" && os.Geteuid() == 0 {
		if u, err := user.Lookup(s.RunAs); err == nil {
			if uid, err := strconv.ParseUint(u.Uid, 10, 32); err == nil {
				if gid, err := strconv.ParseUint(u.Gid, 10, 32); err == nil {
					cmd.SysProcAttr.Credential = &syscall.Credential{
						Uid: uint32(uid),
						Gid: uint32(gid),
					}
				}
			}
		}
	}
	return nil
}

func (m *manager) startCmd(cmd *exec.Cmd) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	return cmd.Start()
}

func (m *manager) postStart(_ *exec.Cmd) error {
	return nil
}

func (p *proc) softStop() {
	if p.pid > 0 {
		_ = syscall.Kill(-p.pid, syscall.SIGTERM)
		_ = syscall.Kill(p.pid, syscall.SIGTERM)
	}
}

func (p *proc) hardKill() {
	if p.pid > 0 {
		_ = syscall.Kill(-p.pid, syscall.SIGKILL)
		_ = syscall.Kill(p.pid, syscall.SIGKILL)
	}
	if p.cmd != nil && p.cmd.Process != nil {
		_ = p.cmd.Process.Kill()
	}
}
