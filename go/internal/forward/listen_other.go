//go:build !windows

package forward

import "syscall"

// exclusiveControl: вне Windows SO_EXCLUSIVEADDRUSE нет (как v2: hasattr).
func exclusiveControl(network, address string, c syscall.RawConn) error { return nil }
