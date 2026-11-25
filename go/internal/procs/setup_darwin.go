//go:build darwin

package procs

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
	"syscall"
	"time"

	"remoteagents/internal/api"
)

type platformState struct{ pgid int }

func newPlatformState() (platformState, error) {
	return platformState{}, nil
}

func (m *manager) terminatePlatform() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.platform.pgid > 0 {
		_ = syscall.Kill(-m.platform.pgid, syscall.SIGKILL)
		m.platform.pgid = 0
	}
}

func (m *manager) setupCmd(cmd *exec.Cmd, s api.ProcSpec) error {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
	// An empty group disappears when its last member exits.
	if m.platform.pgid > 0 && syscall.Kill(-m.platform.pgid, 0) == syscall.ESRCH {
		m.platform.pgid = 0
	}
	cmd.SysProcAttr.Pgid = m.platform.pgid

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

func (m *manager) postStart(cmd *exec.Cmd) error {
	if m.platform.pgid == 0 {
		m.platform.pgid = cmd.Process.Pid
	}
	return nil
}

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

func processStarted(ctx context.Context, cmd *exec.Cmd) (time.Time, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/bin/ps", "-p", strconv.Itoa(cmd.Process.Pid), "-o", "lstart=").Output()
	if err != nil {
		return time.Time{}, err
	}
	t, err := time.ParseInLocation("Mon Jan 2 15:04:05 2006", strings.TrimSpace(string(out)), time.Local)
	return t.UTC(), err
}

// Do not kill the shared group merely because one member has exited.
func (p *proc) reapExited() {}

func (p *proc) groupID() int {
	if p.cmd != nil && p.cmd.SysProcAttr != nil && p.cmd.SysProcAttr.Pgid > 0 {
		return p.cmd.SysProcAttr.Pgid
	}
	return p.pid
}
