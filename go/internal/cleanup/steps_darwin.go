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
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil && err != syscall.ESRCH {
		return err
	}
	timer := time.NewTimer(500 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-ctx.Done():
	case <-timer.C:
	}
	matches, err = processMatches(ctx, t, pid)
	if err != nil || !matches {
		return err
	}
	if err := syscall.Kill(pid, syscall.SIGKILL); err != nil && err != syscall.ESRCH {
		return err
	}
	return nil
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
	return bytes.Contains(out, []byte(dest))
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
	return true
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
