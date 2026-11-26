//go:build windows

package core

import (
	"errors"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"

	"remoteagents/internal/api"
)

// lockFile берёт эксклюзивную блокировку без ожидания; занято → api.ErrBusy.
func lockFile(path string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	var o windows.Overlapped
	if err := windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &o); err != nil {
		_ = f.Close()
		if errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
			return nil, api.ErrBusy
		}
		return nil, err
	}
	return func() {
		_ = windows.UnlockFileEx(windows.Handle(f.Fd()), 0, 1, 0, &o)
		_ = f.Close()
	}, nil
}
