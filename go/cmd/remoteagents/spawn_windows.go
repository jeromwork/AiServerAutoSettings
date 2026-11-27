//go:build windows

package main

import (
	"os"
	"os/exec"
	"syscall"

	"golang.org/x/sys/windows"

	"remoteagents/internal/api"
)

// spawnSupervisor запускает новый сторож отдельным процессом (без окна, вне задания родителя, если оно позволяет).
func spawnSupervisor(exe string, mode api.Mode, args []string) error {
	var err error
	for _, flags := range []uint32{
		windows.DETACHED_PROCESS | windows.CREATE_NEW_PROCESS_GROUP | windows.CREATE_BREAKAWAY_FROM_JOB,
		windows.DETACHED_PROCESS | windows.CREATE_NEW_PROCESS_GROUP, // задание не допускает выход из него
	} {
		cmd := exec.Command(exe, supervisorArgs(mode, args)...)
		cmd.Env = append(os.Environ(), "RA_REDIRECTED=1")
		cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: flags, HideWindow: true}
		if err = cmd.Start(); err == nil {
			_ = cmd.Process.Release()
			return nil
		}
	}
	return err
}
