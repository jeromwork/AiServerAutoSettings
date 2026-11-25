//go:build windows

package platform

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
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
			path = "powershell.exe"
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
			path = "cmd.exe"
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

func startProc(ctx context.Context, pr api.Procs, runAs, path string, args []string, cwd string, r api.ExecReq, proc *execProc) error {
	outW := &streamWriter{proc: proc, stream: "out"}
	errW := &streamWriter{proc: proc, stream: "err"}

	if pr != nil {
		spec := api.ProcSpec{
			Name:   "exec:" + proc.id,
			Path:   path,
			Args:   args[1:],
			Dir:    cwd,
			RunAs:  runAs,
			Stdout: outW,
			Stderr: errW,
			Stream: api.StreamShell,
		}
		p, err := pr.Start(ctx, spec)
		if err != nil {
			return fmt.Errorf("shell: start-failed: %w", err)
		}
		proc.setKill(func() error {
			stopCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			defer cancel()
			return p.Stop(stopCtx)
		})
		go func() {
			select {
			case <-p.Done():
			case <-ctx.Done():
				_ = proc.Kill()
				<-p.Done()
			}
			proc.finish(p.ExitCode())
		}()
		return nil
	}

	if runAs != "" {
		return fmt.Errorf("shell: run-as-unavailable: process manager required")
	}
	var cmdArgs []string
	if len(args) > 1 {
		cmdArgs = args[1:]
	}
	cmd := exec.CommandContext(ctx, path, cmdArgs...)
	cmd.Dir = cwd
	cmd.Stdout = outW
	cmd.Stderr = errW
	cmd.WaitDelay = time.Second

	if strings.ToLower(strings.TrimSpace(r.Shell)) == "cmd" {
		cmd.SysProcAttr = &syscall.SysProcAttr{
			CmdLine: fmt.Sprintf(`cmd.exe /d /s /c "chcp 65001>nul & %s"`, r.Cmd),
		}
	}

	cmd.Cancel = func() error {
		killCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		// Match v2: terminate the complete cmd/PowerShell tree.
		treeErr := exec.CommandContext(killCtx, "taskkill.exe", "/F", "/T", "/PID", fmt.Sprint(cmd.Process.Pid)).Run()
		err := cmd.Process.Kill()
		if err == os.ErrProcessDone {
			return nil
		}
		if err != nil {
			return err
		}
		return treeErr
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("shell: start-failed: %w", err)
	}

	proc.setKill(func() error {
		if cmd.Process == nil {
			return nil
		}
		return cmd.Cancel()
	})

	go func() {
		err := cmd.Wait()
		code := 0
		if err != nil {
			if exitErr, ok := err.(*exec.ExitError); ok {
				code = exitErr.ExitCode()
			} else {
				code = 1
			}
		}
		proc.finish(code)
	}()

	return nil
}
