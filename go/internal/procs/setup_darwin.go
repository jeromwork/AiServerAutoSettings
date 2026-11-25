//go:build darwin

package procs

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

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
	// Each managed process owns its group; Stop must preserve siblings.
	cmd.SysProcAttr.Pgid = 0

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
	return cmd.Start()
}

func (m *manager) postStart(_ *exec.Cmd) error { return nil }

func (p *proc) softStop() {
	if p.pid > 0 {
		_ = syscall.Kill(-p.groupID(), syscall.SIGTERM)
	}
}

func (p *proc) hardKill() {
	if p.pid > 0 {
		_ = syscall.Kill(-p.groupID(), syscall.SIGKILL)
	}
	if p.cmd != nil && p.cmd.Process != nil {
		_ = p.cmd.Process.Kill()
	}
}

func (m *manager) releaseCmd(_ *exec.Cmd) {}

func processStarted(_ context.Context, cmd *exec.Cmd) (time.Time, error) {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", cmd.Process.Pid)
	if err != nil {
		return time.Time{}, err
	}
	return time.Unix(info.Proc.P_starttime.Sec, int64(info.Proc.P_starttime.Usec)*1000).UTC(), nil
}

// Darwin has no exported waitid wrapper in x/sys. Observe SZOMB through
// sysctl without reaping, so PID/PGID cannot be reused before retirement.
func waitExited(cmd *exec.Cmd) error {
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for {
		info, err := unix.SysctlKinfoProc("kern.proc.pid", cmd.Process.Pid)
		if err != nil {
			return err
		}
		const szomb = 5
		if info.Proc.P_stat == szomb {
			return nil
		}
		<-ticker.C
	}
}

func (p *proc) groupID() int { return p.pid }
