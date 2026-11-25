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

	"golang.org/x/sys/unix"

	"remoteagents/internal/api"
)

func (m *manager) setupCmd(cmd *exec.Cmd, s api.ProcSpec) error {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
	cmd.SysProcAttr.Pgid = m.platform.pgid
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

func (m *manager) postStart(_ *exec.Cmd) error { return nil }

func (m *manager) releaseCmd(cmd *exec.Cmd) {
	if v, ok := m.platform.releases.LoadAndDelete(cmd); ok {
		close(v.(chan struct{}))
	}
}

// Linux exports process birth time in USER_HZ (100 ticks per second).
var bootTime = sync.OnceValues(func() (int64, error) {
	system, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(string(system), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && f[0] == "btime" {
			return strconv.ParseInt(f[1], 10, 64)
		}
	}
	return 0, fmt.Errorf("missing boot time")
})

func inspectProcess(pid int) (processIdentity, error) {
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return processIdentity{}, err
	}
	end := strings.LastIndexByte(string(stat), ')')
	if end < 0 {
		return processIdentity{}, fmt.Errorf("invalid process stat")
	}
	fields := strings.Fields(string(stat[end+1:]))
	if len(fields) < 50 {
		return processIdentity{}, fmt.Errorf("short process stat")
	}
	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return processIdentity{}, err
	}
	ticks, err := strconv.ParseInt(fields[19], 10, 64)
	if err != nil {
		return processIdentity{}, err
	}
	status, err := strconv.Atoi(fields[49])
	if err != nil {
		return processIdentity{}, err
	}
	boot, err := bootTime()
	if err != nil {
		return processIdentity{}, err
	}
	return processIdentity{pid: pid, ppid: ppid, status: status,
		live:    fields[0] != "Z" && fields[0] != "X",
		started: time.Unix(boot+ticks/100, (ticks%100)*10000000).UTC()}, nil
}

func processStarted(_ context.Context, cmd *exec.Cmd) (time.Time, error) {
	identity, err := inspectProcess(cmd.Process.Pid)
	return identity.started, err
}

func processTable() []processIdentity {
	entries, _ := os.ReadDir("/proc")
	var table []processIdentity
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		identity, err := inspectProcess(pid)
		if err == nil {
			table = append(table, identity)
		}
	}
	return table
}

// WNOWAIT leaves the zombie leader reserved until group cleanup and retirement.
func waitExited(cmd *exec.Cmd) error {
	var info unix.Siginfo
	for {
		err := unix.Waitid(unix.P_PID, cmd.Process.Pid, &info, unix.WEXITED|unix.WNOWAIT, nil)
		if err != unix.EINTR {
			return err
		}
	}
}
