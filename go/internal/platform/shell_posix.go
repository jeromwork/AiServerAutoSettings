//go:build linux || darwin

package platform

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
	"syscall"
	"time"

	"remoteagents/internal/api"
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

func userCredential(username string) (*syscall.Credential, error) {
	if username == "" {
		return nil, nil
	}
	u, err := user.Lookup(username)
	if err != nil {
		return nil, fmt.Errorf("shell: user-not-found: %w", err)
	}
	uid, err := strconv.ParseUint(u.Uid, 10, 32)
	if err != nil {
		return nil, fmt.Errorf("shell: parse-uid: %w", err)
	}
	gid, err := strconv.ParseUint(u.Gid, 10, 32)
	if err != nil {
		return nil, fmt.Errorf("shell: parse-gid: %w", err)
	}
	return &syscall.Credential{
		Uid: uint32(uid),
		Gid: uint32(gid),
	}, nil
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

func startProc(ctx context.Context, pr api.Procs, runAs, path string, args []string, cwd string, r api.ExecReq, proc *execProc) error {
	outW := &streamWriter{proc: proc, stream: "out"}
	errW := &streamWriter{proc: proc, stream: "err"}

	if pr != nil {
		spec := api.ProcSpec{
			Name:   "exec:" + proc.id,
			Path:   path,
			Args:   args,
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
		proc.killFn = func() error {
			stopCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			defer cancel()
			return p.Stop(stopCtx)
		}
		go func() {
			<-p.Done()
			proc.finish(p.ExitCode())
		}()
		return nil
	}

	var cmdArgs []string
	if len(args) > 1 {
		cmdArgs = args[1:]
	}
	cmd := exec.CommandContext(ctx, path, cmdArgs...)
	cmd.Dir = cwd
	cmd.Stdout = outW
	cmd.Stderr = errW

	cred, err := userCredential(runAs)
	if err != nil {
		return err
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setpgid:    true,
		Credential: cred,
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("shell: start-failed: %w", err)
	}

	proc.killFn = func() error {
		if cmd.Process == nil {
			return nil
		}
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		return cmd.Process.Kill()
	}

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
