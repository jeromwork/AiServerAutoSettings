//go:build linux || darwin

package disk

import (
	"errors"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

var errLocked = errors.New("disk: home занят другим процессом")

// lockFile — эксклюзивная блокировка без ожидания; ОС снимает её при любом завершении процесса.
func lockFile(path string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = f.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, errLocked
		}
		return nil, err
	}
	return func() {
		_ = unix.Flock(int(f.Fd()), unix.LOCK_UN)
		_ = f.Close()
	}, nil
}
