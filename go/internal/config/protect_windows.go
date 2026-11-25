//go:build windows

package config

import (
	"context"
	"os/exec"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"remoteagents/internal/api"
)

// v2 _protect: restrict secret files to the current user, SYSTEM and Administrators.
func protect(path string, log api.Logger) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "icacls", path, "/inheritance:r", "/grant:r", "*S-1-5-18:F", "*S-1-5-32-544:F", "*"+user.User.Sid.String()+":F")
		cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000}
		err = cmd.Run()
	}
	if err != nil && log != nil {
		log.Warn("acl.failed", "file", path)
	}
}
