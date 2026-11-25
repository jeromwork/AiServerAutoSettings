//go:build linux

package procs

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"runtime"
	"strconv"
	"sync"
	"syscall"

	"remoteagents/internal/api"
)

type platformState struct{ releases sync.Map }

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

	if s.RunAs != "" {
		u, err := user.Lookup(s.RunAs)
		if err != nil {
			return err
		}
		uid, err := strconv.ParseUint(u.Uid, 10, 32)
		if err != nil {
			return err
		}
		gid, err := strconv.ParseUint(u.Gid, 10, 32)
		if err != nil {
			return err
		}
		if os.Geteuid() != 0 && os.Geteuid() != int(uid) {
			return fmt.Errorf("runAs requires root")
		}
		if os.Geteuid() == 0 {
			groups, err := u.GroupIds()
			if err != nil {
				return err
			}
			cred := &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)}
			for _, group := range groups {
				id, err := strconv.ParseUint(group, 10, 32)
				if err != nil {
					return err
				}
				cred.Groups = append(cred.Groups, uint32(id))
			}
			cmd.SysProcAttr.Credential = cred
		}
	}
	return nil
}

func (m *manager) startCmd(cmd *exec.Cmd, _ context.Context) error {
	ready := make(chan error, 1)
	release := make(chan struct{})
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		err := cmd.Start()
		ready <- err
		if err == nil {
			<-release
		}
	}()
	if err := <-ready; err != nil {
		return err
	}
	m.platform.releases.Store(cmd, release)
	return nil
}

func (m *manager) postStart(_ *exec.Cmd) error {
	return nil
}

func (p *proc) softStop() {
	if p.pid > 0 {
		_ = syscall.Kill(-p.pid, syscall.SIGTERM)
	}
}

func (p *proc) hardKill() {
	if p.pid > 0 {
		_ = syscall.Kill(-p.pid, syscall.SIGKILL)
	}
	if p.cmd != nil && p.cmd.Process != nil {
		_ = p.cmd.Process.Kill()
	}
}

func (m *manager) releaseCmd(cmd *exec.Cmd) {
	if v, ok := m.platform.releases.LoadAndDelete(cmd); ok {
		close(v.(chan struct{}))
	}
}
