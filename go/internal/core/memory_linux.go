package core

import "golang.org/x/sys/unix"

func rssBytes() uint64 {
	var r unix.Rusage
	if unix.Getrusage(unix.RUSAGE_SELF, &r) != nil {
		return 0
	}
	return uint64(r.Maxrss) * 1024
}
