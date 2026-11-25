//go:build windows

package platform

import (
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"unicode/utf16"

	"remoteagents/internal/api"
)

func (p *stubPlatform) NewShell(log api.Logger, pr api.Procs, runAs string) api.Shell {
	return NewShell(log, pr, runAs)
}

func encodeUTF16LE(s string) []byte {
	u16 := utf16.Encode([]rune(s))
	buf := make([]byte, len(u16)*2)
	for i, v := range u16 {
		binary.LittleEndian.PutUint16(buf[i*2:], v)
	}
	return buf
}

func buildShellCommand(shell, cmd string) (string, []string, error) {
	sh := strings.ToLower(strings.TrimSpace(shell))
	switch sh {
	case "", "powershell":
		script := "[Console]::OutputEncoding=[Text.Encoding]::UTF8\n" + cmd
		b64 := base64.StdEncoding.EncodeToString(encodeUTF16LE(script))
		path, err := exec.LookPath("powershell.exe")
		if err != nil {
			return "", nil, fmt.Errorf("shell: shell-unavailable: powershell")
		}
		args := []string{
			path,
			"-NoProfile",
			"-NonInteractive",
			"-ExecutionPolicy",
			"Bypass",
			"-EncodedCommand",
			b64,
		}
		return path, args, nil

	case "cmd":
		path, err := exec.LookPath("cmd.exe")
		if err != nil {
			return "", nil, fmt.Errorf("shell: shell-unavailable: cmd")
		}
		args := []string{
			path,
			"/d",
			"/s",
			"/c",
			"chcp 65001>nul & " + cmd,
		}
		return path, args, nil

	case "sh":
		path, err := exec.LookPath("sh.exe")
		if err != nil {
			path, err = exec.LookPath("sh")
		}
		if err != nil {
			return "", nil, fmt.Errorf("shell: shell-unavailable: %s", shell)
		}
		return path, []string{path, "-c", cmd}, nil

	default:
		path, err := exec.LookPath(sh)
		if err != nil {
			return "", nil, fmt.Errorf("shell: shell-unavailable: %s", shell)
		}
		return path, []string{path, "-c", cmd}, nil
	}
}

func defaultWorkDir(runAs string) string {
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return home
	}
	return "."
}
