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
	"strings"
	"sync"
	"syscall"
	"time"

	"remoteagents/internal/api"
)

type platformState struct {
	releases *sync.Map
	pgid     int
}

func newPlatformState() (platformState, error) {
	return platformState{releases: &sync.Map{}}, nil
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
	// CommandContext must cancel the group, including descendants which ignore
	// SIGTERM, rather than killing only the direct child.
	cmd.Cancel = func() error {
		p := &proc{cmd: cmd, pid: cmd.Process.Pid}
		p.killTree()
		return nil
	}
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

func (m *manager) releaseCmd(cmd *exec.Cmd) {
	if v, ok := m.platform.releases.LoadAndDelete(cmd); ok {
		close(v.(chan struct{}))
	}
}

// processStarted uses the kernel birth time rather than the time Start returned.
// Linux exports process starttime in USER_HZ (100 ticks per second).
func processStarted(_ context.Context, cmd *exec.Cmd) (time.Time, error) {
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", cmd.Process.Pid))
	if err != nil {
		return time.Time{}, err
	}
	end := strings.LastIndexByte(string(stat), ')')
	if end < 0 {
		return time.Time{}, fmt.Errorf("invalid process stat")
	}
	fields := strings.Fields(string(stat[end+1:]))
	if len(fields) < 20 {
		return time.Time{}, fmt.Errorf("short process stat")
	}
	ticks, err := strconv.ParseInt(fields[19], 10, 64)
	if err != nil {
		return time.Time{}, err
	}
	system, err := os.ReadFile("/proc/stat")
	if err != nil {
		return time.Time{}, err
	}
	for _, line := range strings.Split(string(system), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && f[0] == "btime" {
			boot, err := strconv.ParseInt(f[1], 10, 64)
			if err != nil {
				return time.Time{}, err
			}
			return time.Unix(boot+ticks/100, (ticks%100)*10000000).UTC(), nil
		}
	}
	return time.Time{}, fmt.Errorf("missing boot time")
}

// Preserve siblings on ordinary exit, but clean the group on shutdown or when
// its final managed leader exits. Called with the manager mutex held.
func (p *proc) reapExited(cleanGroup bool) {
	if cleanGroup {
		p.killTree()
	}
}

func (p *proc) groupID() int {
	if p.cmd != nil && p.cmd.SysProcAttr != nil && p.cmd.SysProcAttr.Pgid > 0 {
		return p.cmd.SysProcAttr.Pgid
	}
	return p.pid
}
