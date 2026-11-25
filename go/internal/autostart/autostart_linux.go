//go:build linux

package autostart

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const unitName = "remoteagents.service"

func unitPath() (string, error) {
	h, err := os.UserHomeDir()
	return filepath.Join(h, ".config", "systemd", "user", unitName), err
}

// User-служба systemd: root не нужен.
func Enable(exe string) error {
	if strings.ContainsAny(exe, "\"\r\n") {
		return fmt.Errorf("autostart: bad path")
	}
	p, err := unitPath()
	if err != nil {
		return err
	}
	unit := "[Unit]\nDescription=RemoteAgents\n\n[Service]\nExecStart=\"" + exe + "\" --autostart\nRestart=on-failure\n\n[Install]\nWantedBy=default.target\n"
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(p, []byte(unit), 0o644); err != nil {
		return err
	}
	if err := run("systemctl", "--user", "daemon-reload"); err != nil {
		return err
	}
	return run("systemctl", "--user", "enable", "--now", unitName)
}

func Disable() error {
	p, err := unitPath()
	if err != nil {
		return err
	}
	_ = run("systemctl", "--user", "disable", "--now", unitName)
	if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
		return err
	}
	return run("systemctl", "--user", "daemon-reload")
}

func Enabled() bool { return run("systemctl", "--user", "is-enabled", unitName) == nil }
