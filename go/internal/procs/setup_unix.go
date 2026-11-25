//go:build linux || darwin

package procs

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"syscall"

	"remoteagents/internal/api"
)

type platformProcess struct{}

func setupProcess(cmd *exec.Cmd, s api.ProcSpec) (platformProcess, error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pgid: 0}
	setDeathSignal(cmd.SysProcAttr)
	if s.RunAs == "" {
		return platformProcess{}, nil
	}
	u, err := user.Lookup(s.RunAs)
	if err != nil {
		return platformProcess{}, err
	}
	uid, err := strconv.ParseUint(u.Uid, 10, 32)
	if err != nil {
		return platformProcess{}, err
	}
	gid, err := strconv.ParseUint(u.Gid, 10, 32)
	if err != nil {
		return platformProcess{}, err
	}
	if os.Geteuid() != 0 {
		if os.Geteuid() != int(uid) {
			return platformProcess{}, fmt.Errorf("runAs requires root")
		}
		return platformProcess{}, nil
	}
	groups, err := u.GroupIds()
	if err != nil {
		return platformProcess{}, err
	}
	cred := &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)}
	for _, group := range groups {
		id, err := strconv.ParseUint(group, 10, 32)
		if err != nil {
			return platformProcess{}, err
		}
		cred.Groups = append(cred.Groups, uint32(id))
	}
	cmd.SysProcAttr.Credential = cred
	return platformProcess{}, nil
}

func (p *proc) attach() error { return nil }
func (p *proc) softStop()     { _ = syscall.Kill(-p.PID(), syscall.SIGTERM) }
func (p *proc) hardKill()     { _ = syscall.Kill(-p.PID(), syscall.SIGKILL) }
func (p *proc) release()      {}
