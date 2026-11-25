//go:build linux

package supervise

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func setSysProcAttr(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
}

func stopProcessGroup(cmd *exec.Cmd) {
	if cmd != nil && cmd.Process != nil && cmd.Process.Pid > 0 {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
}

func killProcessGroup(cmd *exec.Cmd) {
	if cmd != nil && cmd.Process != nil && cmd.Process.Pid > 0 {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
}

func attachProcess(cmd *exec.Cmd) (func(), error) { return func() {}, nil }

// Linux exposes starttime in USER_HZ (100 ticks per second), relative to btime.
func processStarted(cmd *exec.Cmd) (time.Time, error) {
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", cmd.Process.Pid))
	if err != nil {
		return time.Time{}, err
	}
	end := strings.LastIndexByte(string(stat), ')')
	if end < 0 {
		return time.Time{}, fmt.Errorf("supervise: process-start: invalid stat")
	}
	fields := strings.Fields(string(stat)[end+1:])
	if len(fields) <= 19 {
		return time.Time{}, fmt.Errorf("supervise: process-start: short stat")
	}
	ticks, err := strconv.ParseUint(fields[19], 10, 64)
	if err != nil {
		return time.Time{}, err
	}
	boot, err := os.ReadFile("/proc/stat")
	if err != nil {
		return time.Time{}, err
	}
	for _, line := range strings.Split(string(boot), "\n") {
		if strings.HasPrefix(line, "btime ") {
			seconds, err := strconv.ParseInt(strings.TrimSpace(strings.TrimPrefix(line, "btime ")), 10, 64)
			if err != nil {
				return time.Time{}, err
			}
			return time.Unix(seconds+int64(ticks/100), int64(ticks%100)*int64(10*time.Millisecond)), nil
		}
	}
	return time.Time{}, fmt.Errorf("supervise: process-start: missing btime")
}
