//go:build windows

package forward

import "syscall"

// exclusiveControl: SO_EXCLUSIVEADDRUSE (-5), занятый порт честно даёт ошибку, а не делится.
func exclusiveControl(network, address string, c syscall.RawConn) error {
	var e error
	if err := c.Control(func(fd uintptr) {
		e = syscall.SetsockoptInt(syscall.Handle(fd), syscall.SOL_SOCKET, -5, 1)
	}); err != nil {
		return err
	}
	return e
}
