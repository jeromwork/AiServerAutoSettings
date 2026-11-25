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
	// CommandContext must cancel the group, including descendants which ignore
	// SIGTERM, rather than killing only the direct child.
	cmd.Cancel = func() error {
		p := &proc{cmd: cmd, pid: cmd.Process.Pid}
		p.killTree()
		return nil
	}

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

// Reap descendants of this leader on every exit, without touching siblings.
func (p *proc) reapExited(_ bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.killOnce.Do(p.hardKill)
	p.retired = true
}

func (p *proc) groupID() int { return p.pid }
