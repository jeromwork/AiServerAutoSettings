//go:build windows

package deps

import (
	_ "github.com/kolesnikovae/go-winjob"
	_ "golang.org/x/sys/windows"
)
