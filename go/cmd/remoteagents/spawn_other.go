//go:build !windows

package main

import (
	"os"
	"os/exec"
	"syscall"

	"remoteagents/internal/api"
)

func spawnSupervisor(exe string, mode api.Mode, args []string) error {
	cmd := exec.Command(exe, supervisorArgs(mode, args)...)
	cmd.Env = append(os.Environ(), "RA_REDIRECTED=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}
