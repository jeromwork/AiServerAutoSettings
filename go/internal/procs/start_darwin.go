package procs

import (
	"time"

	"golang.org/x/sys/unix"
)

func processStart(pid int) (string, error) {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return "", err
	}
	return time.Unix(info.Proc.P_starttime.Sec, int64(info.Proc.P_starttime.Usec)*1000).UTC().Format(time.RFC3339Nano), nil
}
