//go:build linux

package core

import "os"

func openFDs() int {
	e, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		return -1
	}
	return len(e)
}
