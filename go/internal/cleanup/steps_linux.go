//go:build linux

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

type linuxSteps struct{}

func init() {
	currentPlatformSteps = &linuxSteps{}
}

func (s *linuxSteps) removeProcess(ctx context.Context, t api.Trace) error {
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
	for i := 0; i < 20; i++ {
		matches, err = processMatches(ctx, t, pid)
		if err != nil || !matches {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(25 * time.Millisecond):
		}
	}
	return fmt.Errorf("process: still alive after kill")
}
func (s *linuxSteps) checkProcess(ctx context.Context, t api.Trace) bool {
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

	target, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", pid))
	if err != nil {
		return false, err
	}
	if target != t.Data["exe"] {
		return false, nil
	}
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return false, err
	}
	fields := strings.Fields(string(stat)[strings.LastIndex(string(stat), ")")+1:])
	if len(fields) < 20 {
		return false, fmt.Errorf("process: invalid stat")
	}
	if fields[0] == "Z" {
		return false, nil
	}
	ticks := fields[19]
	// /proc start ticks are unambiguous and can be recorded directly by launchers.
	if t.Data["start"] == ticks {
		return true, nil
	}
	boot, err := os.ReadFile("/proc/stat")
	if err != nil {
		return false, err
	}
	var base int64
	for _, line := range strings.Split(string(boot), "\n") {
		if strings.HasPrefix(line, "btime ") {
			base, _ = strconv.ParseInt(strings.TrimPrefix(line, "btime "), 10, 64)
		}
	}
	n, err := strconv.ParseInt(ticks, 10, 64)
	if err != nil {
		return false, err
	}
	started, err := time.Parse(time.RFC3339Nano, t.Data["start"])
	if err != nil {
		return false, fmt.Errorf("process: invalid start identity")
	}
	delta := started.Sub(time.Unix(base+n/100, (n%100)*10000000))
	if delta < 0 {
		delta = -delta
	}
	return delta < time.Second, nil
}

func (s *linuxSteps) removeAdapter(ctx context.Context, name string) error {
	if name == "" {
		return nil
	}
	if _, err := net.InterfaceByName(name); err != nil {
		return nil
	}
	for attempt := 0; attempt < 3; attempt++ {
		iface, err := net.InterfaceByName(name)
		if err != nil {
			return nil
		}
		if (iface.Flags & net.FlagUp) == 0 {
			break
		}
		if attempt > 0 {
			time.Sleep(2 * time.Second)
		}
	}
	cmd := exec.CommandContext(ctx, "ip", "link", "del", name)
	return cmd.Run()
}

func (s *linuxSteps) checkAdapter(ctx context.Context, name string) bool {
	if name == "" {
		return false
	}
	_, err := net.InterfaceByName(name)
	return err == nil
}

func (s *linuxSteps) removeRoute(ctx context.Context, dest, iface string) error {
	if dest == "" || iface == "" {
		return nil
	}
	if !s.checkRoute(ctx, dest, iface) {
		return nil
	}
	cmd := exec.CommandContext(ctx, "ip", "route", "del", dest, "dev", iface)
	return cmd.Run()
}

func (s *linuxSteps) checkRoute(ctx context.Context, dest, iface string) bool {
	if dest == "" || iface == "" {
		return false
	}
	out, err := exec.CommandContext(ctx, "ip", "route", "show", dest, "dev", iface).Output()
	return err != nil || len(bytes.TrimSpace(out)) > 0
}

func (s *linuxSteps) removeRule(ctx context.Context, prio, table string) error {
	if prio == "" && table == "" {
		return nil
	}
	if !s.checkRule(ctx, prio, table) {
		return nil
	}
	var args []string
	if prio != "" && table != "" {
		args = []string{"rule", "del", "pref", prio, "table", table}
	} else if prio != "" {
		args = []string{"rule", "del", "pref", prio}
	} else {
		args = []string{"rule", "del", "table", table}
	}
	cmd := exec.CommandContext(ctx, "ip", args...)
	return cmd.Run()
}

func (s *linuxSteps) checkRule(ctx context.Context, prio, table string) bool {
	if prio == "" && table == "" {
		return false
	}
	out, err := exec.CommandContext(ctx, "ip", "rule", "show").Output()
	if err != nil {
		return true
	}
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		matchPrio := prio == "" || strings.HasPrefix(strings.TrimSpace(line), prio+":")
		matchTable := table == "" || strings.Contains(line+" ", "lookup "+table+" ") || strings.Contains(line+" ", "table "+table+" ")
		if matchPrio && matchTable {
			return true
		}
	}
	return false
}

func (s *linuxSteps) removeFirewall(ctx context.Context, name string) error {
	if name == "" {
		return nil
	}
	if !s.checkFirewall(ctx, name) {
		return nil
	}
	cmd := exec.CommandContext(ctx, "nft", "delete", "table", "inet", name)
	return cmd.Run()
}

func (s *linuxSteps) checkFirewall(ctx context.Context, name string) bool {
	if name == "" {
		return false
	}
	out, err := exec.CommandContext(ctx, "nft", "list", "tables").Output()
	if err != nil {
		return true
	}
	return bytes.Contains(out, []byte("table inet "+name+"\n"))
}

func (s *linuxSteps) lock(path string) (func(), error) {
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
