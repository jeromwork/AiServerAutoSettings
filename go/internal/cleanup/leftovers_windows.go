//go:build windows

package cleanup

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"remoteagents/internal/wincon"
	"strconv"
	"unsafe"

	"golang.org/x/sys/windows"
)

func scanPlatformProcesses(home, bin string) (Report, error) {
	rep := Report{
		Found:     []string{},
		Removed:   []string{},
		Unremoved: []string{},
	}

	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return rep, fmt.Errorf("cleanup: snapshot: %w", err)
	}
	defer windows.CloseHandle(snap)

	type procInfo struct {
		pid  uint32
		ppid uint32
	}
	var allProcs []procInfo
	ppidMap := make(map[uint32]uint32)

	var entry windows.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))

	for err = windows.Process32First(snap, &entry); err == nil; err = windows.Process32Next(snap, &entry) {
		pid := entry.ProcessID
		ppid := entry.ParentProcessID
		allProcs = append(allProcs, procInfo{pid: pid, ppid: ppid})
		ppidMap[pid] = ppid
	}

	myPid := uint32(os.Getpid())
	ancestors := make(map[uint32]bool)
	ancestors[myPid] = true
	if ppid := uint32(os.Getppid()); ppid > 0 {
		ancestors[ppid] = true
	}
	curr := myPid
	for curr > 4 {
		pp, ok := ppidMap[curr]
		if !ok || pp <= 4 || ancestors[pp] {
			if ok && pp > 0 {
				ancestors[pp] = true
			}
			break
		}
		ancestors[pp] = true
		curr = pp
	}

	type candidateInfo struct {
		pid uint32
		exe string
	}
	var candidates []candidateInfo

	buf := make([]uint16, 32768)
	for _, p := range allProcs {
		if p.pid <= 4 || ancestors[p.pid] {
			continue
		}

		h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, p.pid)
		if err != nil {
			continue
		}

		n := uint32(len(buf))
		err = windows.QueryFullProcessImageName(h, 0, &buf[0], &n)
		windows.CloseHandle(h)
		if err != nil {
			continue
		}

		exe := windows.UTF16ToString(buf[:n])
		cleanExe := filepath.Clean(exe)
		if isSubpath(cleanExe, home) || isSubpath(cleanExe, bin) {
			candidates = append(candidates, candidateInfo{pid: p.pid, exe: cleanExe})
		}
	}

	for _, c := range candidates {
		desc := fmt.Sprintf("%d (%s)", c.pid, c.exe)
		rep.Found = append(rep.Found, desc)

		if err := killWindowsProcess(c.pid); err != nil {
			rep.Unremoved = append(rep.Unremoved, desc)
		} else {
			rep.Removed = append(rep.Removed, desc)
		}
	}

	return rep, nil
}

func killWindowsProcess(pid uint32) error {
	h, err := windows.OpenProcess(windows.PROCESS_TERMINATE|windows.SYNCHRONIZE, false, pid)
	if err != nil {
		if errors.Is(err, windows.ERROR_INVALID_PARAMETER) || isProcessGoneWindows(pid) {
			return nil
		}
		return err
	}
	defer windows.CloseHandle(h)

	_ = wincon.SendBreak(pid)
	state, _ := windows.WaitForSingleObject(h, 300)
	if state != windows.WAIT_OBJECT_0 {
		cmd := exec.Command("taskkill.exe", "/F", "/T", "/PID", strconv.FormatUint(uint64(pid), 10))
		cmd.SysProcAttr = wincon.HiddenAttr()
		_ = cmd.Run()
		state, _ = windows.WaitForSingleObject(h, 300)
		if state != windows.WAIT_OBJECT_0 {
			_ = windows.TerminateProcess(h, 1)
			state, _ = windows.WaitForSingleObject(h, 500)
		}
	}

	if state == windows.WAIT_OBJECT_0 || isProcessGoneWindows(pid) {
		return nil
	}
	return fmt.Errorf("process %d failed to terminate", pid)
}

func isProcessGoneWindows(pid uint32) bool {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE, false, pid)
	if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
		return true
	}
	if err != nil {
		return false
	}
	defer windows.CloseHandle(h)
	state, err := windows.WaitForSingleObject(h, 0)
	return err == nil && state == windows.WAIT_OBJECT_0
}
