//go:build darwin

package platform

import (
	"os"

	"golang.org/x/sys/unix"
)

func (w *NetWatch) watch() (func() error, error) {
	fd, err := unix.Socket(unix.AF_ROUTE, unix.SOCK_RAW, unix.AF_UNSPEC)
	if err != nil {
		return nil, err
	}
	unix.CloseOnExec(fd)
	if err = unix.SetNonblock(fd, true); err != nil {
		unix.Close(fd)
		return nil, err
	}
	f := os.NewFile(uintptr(fd), "netwatch")
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 65536)
		for {
			n, err := f.Read(buf)
			if err != nil {
				return
			}
			if n < 4 {
				continue
			}
			switch buf[3] {
			case unix.RTM_ADD, unix.RTM_DELETE, unix.RTM_CHANGE, unix.RTM_NEWADDR, unix.RTM_DELADDR, unix.RTM_IFINFO:
				w.changed()
			}
		}
	}()
	return func() error {
		err := f.Close()
		<-done
		return err
	}, nil
}
