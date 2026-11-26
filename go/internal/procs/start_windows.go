package procs

import (
	"time"

	"golang.org/x/sys/windows"
)

func processStart(pid int) (string, error) {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return "", err
	}
	defer windows.CloseHandle(h)
	var c, e, k, u windows.Filetime
	if err := windows.GetProcessTimes(h, &c, &e, &k, &u); err != nil {
		return "", err
	}
	return time.Unix(0, c.Nanoseconds()).UTC().Format(time.RFC3339Nano), nil
}
