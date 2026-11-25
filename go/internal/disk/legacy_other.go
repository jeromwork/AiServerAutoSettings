//go:build !windows

package disk

import "context"

func (d *Disk) foreignRunning(context.Context) bool { return false }
func engineLock(string) (func(), error)             { return func() {}, nil }
func isJunction(string) bool                        { return false }
