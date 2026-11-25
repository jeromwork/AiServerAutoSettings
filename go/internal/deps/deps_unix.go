//go:build linux || darwin

package deps

import (
	_ "golang.org/x/sys/unix"
)
