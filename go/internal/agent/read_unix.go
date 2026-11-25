//go:build linux || darwin

package agent

import (
	"os"

	"golang.org/x/sys/unix"
)

// O_NONBLOCK prevents a FIFO swapped in before open from blocking the handler.
// The caller checks the opened descriptor's type before reading any data.
func openRegular(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|unix.O_NONBLOCK, 0)
}
