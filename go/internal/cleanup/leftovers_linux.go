//go:build linux

package cleanup

import (
	"fmt"
	"os"
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

	myPid := os.Getpid()
	ancestors := make(map[int]bool)
	ancestors[myPid] = true
	if ppid := os.Getppid(); ppid > 0 {
		ancestors[ppid] = true
	}
	curr := myPid
	for curr > 1 {
		ppid := linuxPPID(curr)
		if ppid <= 1 || ancestors[ppid] {
			if ppid > 0 {
				ancestors[ppid] = true
			}
			break
		}
		ancestors[ppid] = true
		curr = ppid
	}

	entries, err := os.ReadDir("/proc")
	if err != nil {
		return rep, fmt.Errorf("cleanup: scan /proc: %w", err)
	}

	type procItem struct {
		pid int
		exe string
	}
	var candidates []procItem

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 1 {
			continue
		}
		if ancestors[pid] {
			continue
		}

		if isZombieLinux(pid) {
			continue
		}

		exeLink, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", pid))
		if err != nil {
			continue
		}
		exeLink = strings.TrimSuffix(exeLink, " (deleted)")
		cleanExe := filepath.Clean(exeLink)

		if isSubpath(cleanExe, home) || isSubpath(cleanExe, bin) {
			candidates = append(candidates, procItem{pid: pid, exe: cleanExe})
		}
	}

	for _, c := range candidates {
		desc := fmt.Sprintf("%d (%s)", c.pid, c.exe)
		rep.Found = append(rep.Found, desc)

		if err := killLinuxProcess(c.pid); err != nil {
			rep.Unremoved = append(rep.Unremoved, desc)
		} else {
			rep.Removed = append(rep.Removed, desc)
		}
	}

	return rep, nil
}

func linuxPPID(pid int) int {
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0
	}
	idx := strings.LastIndex(string(stat), ")")
	if idx == -1 {
		return 0
	}
	fields := strings.Fields(string(stat)[idx+1:])
	if len(fields) < 2 {
		return 0
	}
	ppid, _ := strconv.Atoi(fields[1])
	return ppid
}

func isZombieLinux(pid int) bool {
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return false
	}
	idx := strings.LastIndex(string(stat), ")")
	if idx == -1 {
		return false
	}
	fields := strings.Fields(string(stat)[idx+1:])
	return len(fields) > 0 && fields[0] == "Z"
}

func killLinuxProcess(pid int) error {
	if err := syscall.Kill(pid, 0); err == syscall.ESRCH || isZombieLinux(pid) {
		return nil
	}
	_ = syscall.Kill(pid, syscall.SIGTERM)
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
		if err := syscall.Kill(pid, 0); err == syscall.ESRCH || isZombieLinux(pid) {
			return nil
		}
	}
	_ = syscall.Kill(pid, syscall.SIGKILL)
	deadline = time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
		if err := syscall.Kill(pid, 0); err == syscall.ESRCH || isZombieLinux(pid) {
			return nil
		}
	}
	if err := syscall.Kill(pid, 0); err == syscall.ESRCH || isZombieLinux(pid) {
		return nil
	}
	return fmt.Errorf("process %d still alive", pid)
}
