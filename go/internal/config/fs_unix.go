//go:build !windows

package config

import "os"

func replace(from, to string) error { return os.Rename(from, to) }

func syncDir(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := f.Sync(); err != nil {
		return nil // some filesystems refuse directory fsync; the rename itself succeeded
	}
	return nil
}

func protectDir(dir string) error { return os.Chmod(dir, 0o700) }
