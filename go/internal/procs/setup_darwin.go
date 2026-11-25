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

	"golang.org/x/sys/unix"

	"remoteagents/internal/api"
)

func (m *manager) setupCmd(cmd *exec.Cmd, s api.ProcSpec) error {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
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

func (m *manager) postStart(_ *exec.Cmd) error { return nil }

func (m *manager) releaseCmd(_ *exec.Cmd) {}

func inspectProcess(pid int) (processIdentity, error) {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return processIdentity{}, err
	}
	if info.Proc.P_pid != int32(pid) {
		return processIdentity{}, fmt.Errorf("process not found")
	}
	return processIdentity{pid: pid, status: int(info.Proc.P_xstat),
		live:    info.Proc.P_stat != 5,
		started: time.Unix(info.Proc.P_starttime.Sec, int64(info.Proc.P_starttime.Usec)*1000).UTC()}, nil
}

func processStarted(_ context.Context, cmd *exec.Cmd) (time.Time, error) {
	identity, err := inspectProcess(cmd.Process.Pid)
	return identity.started, err
}

func processTable() []processIdentity {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "/bin/ps", "-axo", "pid=,ppid=").Output()
	if err != nil {
		return nil
	}
	var table []processIdentity
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		ppid, err := strconv.Atoi(fields[1])
		if err != nil {
			continue
		}
		identity, err := inspectProcess(pid)
		if err == nil {
			identity.ppid = ppid
			table = append(table, identity)
		}
	}
	return table
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
