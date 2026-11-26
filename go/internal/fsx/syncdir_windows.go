//go:build windows

// Package fsx holds small cross-platform filesystem helpers.
package fsx

// SyncDir is a no-op on Windows: a directory cannot be fsynced there
// (Sync on a directory handle returns "Access is denied").
func SyncDir(string) error { return nil }
