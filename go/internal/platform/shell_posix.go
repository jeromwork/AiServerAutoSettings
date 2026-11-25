//go:build linux || darwin

package platform

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strings"
)

func buildShellCommand(shell, cmd string) (string, []string, error) {
	sh := strings.ToLower(strings.TrimSpace(shell))
	switch sh {
	case "", "sh":
		path, err := exec.LookPath("/bin/sh")
		if err != nil {
			path, err = exec.LookPath("sh")
		}
		if err != nil {
			return "", nil, fmt.Errorf("shell: shell-unavailable: %s", shell)
		}
		return path, []string{path, "-c", cmd}, nil

	case "powershell":
		path, err := exec.LookPath("pwsh")
		if err != nil {
			return "", nil, fmt.Errorf("shell: shell-unavailable: %s", shell)
		}
		return path, []string{path, "-NoProfile", "-NonInteractive", "-Command", cmd}, nil

	case "cmd":
		path, err := exec.LookPath("cmd")
		if err != nil {
			return "", nil, fmt.Errorf("shell: shell-unavailable: %s", shell)
		}
		return path, []string{path, "/c", cmd}, nil

	default:
		path, err := exec.LookPath(sh)
		if err != nil {
			return "", nil, fmt.Errorf("shell: shell-unavailable: %s", shell)
		}
		return path, []string{path, "-c", cmd}, nil
	}
}

func defaultWorkDir(runAs string) string {
	if runAs != "" {
		if u, err := user.Lookup(runAs); err == nil && u.HomeDir != "" {
			return u.HomeDir
		}
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return home
	}
	return "."
}
