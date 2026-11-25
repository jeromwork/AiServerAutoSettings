//go:build linux

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
)

// OpenBrowser starts the desktop opener; only the launcher has a bounded lifetime.
func (p *stubPlatform) OpenBrowser(url, runAs string) error {
	if !strings.HasPrefix(url, "http://") && !strings.HasPrefix(url, "https://") {
		return fmt.Errorf("platform: browser-url: expected HTTP(S) URL")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	cmd := exec.CommandContext(ctx, "xdg-open", url)
	defer func() {
		if cmd.Process == nil {
			cancel()
		}
	}()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if runAs != "" {
		u, err := user.Lookup(runAs)
		if err != nil {
			return fmt.Errorf("platform: browser-user: %w", err)
		}
		uid, err := strconv.ParseUint(u.Uid, 10, 32)
		if err != nil {
			return fmt.Errorf("platform: browser-uid: %w", err)
		}
		gid, err := strconv.ParseUint(u.Gid, 10, 32)
		if err != nil {
			return fmt.Errorf("platform: browser-gid: %w", err)
		}
		if uint32(os.Geteuid()) != uint32(uid) {
			if os.Geteuid() != 0 {
				return fmt.Errorf("platform: browser-permission: cannot switch user")
			}
			groups, err := u.GroupIds()
			if err != nil {
				return fmt.Errorf("platform: browser-groups: %w", err)
			}
			credential := &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)}
			for _, group := range groups {
				id, err := strconv.ParseUint(group, 10, 32)
				if err != nil {
					return fmt.Errorf("platform: browser-group: %w", err)
				}
				credential.Groups = append(credential.Groups, uint32(id))
			}
			cmd.SysProcAttr.Credential = credential
		}
		cmd.Env = append(os.Environ(), "HOME="+u.HomeDir, "USER="+u.Username, "LOGNAME="+u.Username)
		cmd.Dir = u.HomeDir
		cmd.Env = append(cmd.Env, "XDG_RUNTIME_DIR=/run/user/"+u.Uid, "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"+u.Uid+"/bus")
	}
	if err := cmd.Start(); err != nil {
		cancel()
		return fmt.Errorf("platform: browser-open: %w", err)
	}
	// Reap only the launcher; desktop browser descendants survive its timeout.
	go func() {
		defer cancel()
		_ = cmd.Wait()
	}()
	return nil
}
