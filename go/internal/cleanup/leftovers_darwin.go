//go:build darwin

package cleanup

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func scanPlatformProcesses(home, bin string) (Report, error) {
	rep := Report{
		Found:     []string{},
		Removed:   []string{},
		Unremoved: []string{},
	}

	cmd := exec.Command("ps", "-A", "-o", "pid=,ppid=,comm=")
	out, err := cmd.Output()
	if err != nil {
		return rep, fmt.Errorf("cleanup: ps: %w", err)
	}

	type procItem struct {
		pid  int
		ppid int
		comm string
	}
	var procs []procItem
	ppidMap := make(map[int]int)

	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		pid, err1 := strconv.Atoi(fields[0])
		ppid, err2 := strconv.Atoi(fields[1])
		if err1 != nil || err2 != nil || pid <= 1 {
			continue
		}
		idx := strings.Index(line, fields[1])
		comm := strings.TrimSpace(line[idx+len(fields[1]):])
		procs = append(procs, procItem{pid: pid, ppid: ppid, comm: comm})
		ppidMap[pid] = ppid
	}

	myPid := os.Getpid()
	ancestors := make(map[int]bool)
	ancestors[myPid] = true
	if ppid := os.Getppid(); ppid > 0 {
		ancestors[ppid] = true
	}
	curr := myPid
	for curr > 1 {
		pp, ok := ppidMap[curr]
		if !ok || pp <= 1 || ancestors[pp] {
			if ok && pp > 0 {
				ancestors[pp] = true
			}
			break
		}
		ancestors[pp] = true
		curr = pp
	}

	var candidates []procItem
	for _, p := range procs {
		if ancestors[p.pid] {
			continue
		}
		cleanComm := filepath.Clean(p.comm)
		if isSubpath(cleanComm, home) || isSubpath(cleanComm, bin) {
			candidates = append(candidates, p)
		}
	}

	for _, c := range candidates {
		desc := fmt.Sprintf("%d (%s)", c.pid, c.comm)
		rep.Found = append(rep.Found, desc)

		if err := killDarwinProcess(c.pid); err != nil {
			rep.Unremoved = append(rep.Unremoved, desc)
		} else {
			rep.Removed = append(rep.Removed, desc)
		}
	}

	return rep, nil
}

func killDarwinProcess(pid int) error {
	if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
		return nil
	}
	_ = syscall.Kill(pid, syscall.SIGTERM)
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
		if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
			return nil
		}
	}
	_ = syscall.Kill(pid, syscall.SIGKILL)
	deadline = time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
		if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
			return nil
		}
	}
	if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
		return nil
	}
	return fmt.Errorf("process %d still alive", pid)
}
