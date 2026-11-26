//go:build !windows

// Package fsx holds small cross-platform filesystem helpers.
package fsx

import "os"

// SyncDir fsyncs a directory so a rename/create in it is durable.
// Filesystems that refuse directory fsync are not treated as errors.
func SyncDir(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	_ = f.Sync()
	return nil
}
