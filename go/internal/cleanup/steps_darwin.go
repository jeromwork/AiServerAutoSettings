//go:build darwin

package cleanup

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"

	"remoteagents/internal/api"
)

type darwinSteps struct{}

func init() {
	currentPlatformSteps = &darwinSteps{}
}

func (s *darwinSteps) removeProcess(ctx context.Context, t api.Trace) error {
	pid, err := strconv.Atoi(t.Data["pid"])
	if err != nil || pid <= 1 {
		return fmt.Errorf("process: missing valid pid; intent cannot be resolved")
	}
	if pid == os.Getpid() {
		return fmt.Errorf("process: refusing to stop self")
	}
	matches, err := processMatches(ctx, t, pid)
	if err != nil || !matches {
		return err
	}
	// Procs may place several traced children in one group; the traced PID
	// need not be its leader. Never signal the cleanup process's own group.
	pgid, err := syscall.Getpgid(pid)
	if err != nil {
		return err
	}
	if pgid <= 1 || pgid == syscall.Getpgrp() {
		return fmt.Errorf("process: refusing unsafe process group")
	}
	identity, err := processIdentity(ctx, pid)
	if err != nil {
		return err
	}
	if err := syscall.Kill(-pgid, syscall.SIGTERM); err != nil && err != syscall.ESRCH {
		return err
	}
	timer := time.NewTimer(500 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-ctx.Done():
	case <-timer.C:
	}
	// The traced member may exit on TERM while other group members remain.
	// If its PID was reused or moved groups, preserve the group.
	if err := syscall.Kill(pid, 0); err == nil {
		current, identityErr := processIdentity(ctx, pid)
		if identityErr != nil {
			return identityErr
		}
		currentGroup, groupErr := syscall.Getpgid(pid)
		if groupErr != nil {
			return groupErr
		}
		if current != identity || currentGroup != pgid {
			return fmt.Errorf("process: identity or group changed; group preserved")
		}
	}
	if err := syscall.Kill(-pgid, syscall.SIGKILL); err != nil && err != syscall.ESRCH {
		return err
	}
	return nil
}
func processIdentity(ctx context.Context, pid int) (string, error) {
	out, err := exec.CommandContext(ctx, "ps", "-p", strconv.Itoa(pid), "-o", "lstart=").Output()
	if err != nil {
		return "", err
	}
	identity := strings.TrimSpace(string(out))
	if identity == "" {
		return "", fmt.Errorf("process: missing process identity")
	}
	return identity, nil
}

func (s *darwinSteps) checkProcess(ctx context.Context, t api.Trace) bool {
	pid, err := strconv.Atoi(t.Data["pid"])
	if err != nil || pid <= 1 {
		return true
	}
	matches, err := processMatches(ctx, t, pid)
	return err != nil || matches
}
func processMatches(ctx context.Context, t api.Trace, pid int) (bool, error) {
	if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
		return false, nil
	} else if err != nil {
		return false, err
	}

	// Query separately because executable paths may contain spaces.
	exe, err := exec.CommandContext(ctx, "ps", "-p", strconv.Itoa(pid), "-o", "comm=").Output()
	if err != nil {
		return false, err
	}
	if strings.TrimSpace(string(exe)) != t.Data["exe"] {
		return false, nil
	}
	stamp, err := exec.CommandContext(ctx, "ps", "-p", strconv.Itoa(pid), "-o", "lstart=").Output()
	if err != nil {
		return false, err
	}
	actual, err := time.ParseInLocation("Mon Jan 2 15:04:05 2006", strings.Join(strings.Fields(string(stamp)), " "), time.Local)
	if err != nil {
		return false, err
	}
	wanted, err := time.Parse(time.RFC3339Nano, t.Data["start"])
	if err != nil {
		return false, err
	}
	return actual.Unix() == wanted.Unix(), nil
}

func (s *darwinSteps) removeAdapter(ctx context.Context, name string) error {
	if name == "" {
		return nil
	}
	if _, err := net.InterfaceByName(name); err != nil {
		return nil
	}
	if err := exec.CommandContext(ctx, "ifconfig", name, "down").Run(); err != nil {
		return err
	}
	return exec.CommandContext(ctx, "ifconfig", name, "destroy").Run()
}

func (s *darwinSteps) checkAdapter(ctx context.Context, name string) bool {
	if name == "" {
		return false
	}
	_, err := net.InterfaceByName(name)
	return err == nil
}

func (s *darwinSteps) removeRoute(ctx context.Context, dest, iface string) error {
	if dest == "" {
		return nil
	}
	var args []string
	if iface != "" {
		args = []string{"delete", dest, "-interface", iface}
	} else {
		args = []string{"delete", dest}
	}
	return exec.CommandContext(ctx, "route", args...).Run()
}

func (s *darwinSteps) checkRoute(ctx context.Context, dest, iface string) bool {
	if dest == "" {
		return false
	}
	out, err := exec.CommandContext(ctx, "netstat", "-rn").Output()
	if err != nil {
		return true
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 2 && fields[0] == dest {
			for _, f := range fields[2:] {
				if f == iface {
					return true
				}
			}
		}
	}
	return false
}

func (s *darwinSteps) removeRule(ctx context.Context, prio, table string) error {
	return fmt.Errorf("rule: unsupported on darwin")
}

func (s *darwinSteps) checkRule(ctx context.Context, prio, table string) bool {
	return true
}

func (s *darwinSteps) removeFirewall(ctx context.Context, name string) error {
	return exec.CommandContext(ctx, "pfctl", "-a", name, "-F", "all").Run()
}

func (s *darwinSteps) checkFirewall(ctx context.Context, name string) bool {
	out, err := exec.CommandContext(ctx, "pfctl", "-a", name, "-sr").Output()
	return err != nil || len(bytes.TrimSpace(out)) > 0
}

func (s *darwinSteps) lock(path string) (func(), error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, err
	}
	return func() { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); _ = f.Close() }, nil
}
