//go:build !windows

package config

import "os"

func replace(from, to string) error { return os.Rename(from, to) }

func protectDir(dir string) error { return os.Chmod(dir, 0o700) }
