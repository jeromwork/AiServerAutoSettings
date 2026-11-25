//go:build linux

package platform

import (
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"strings"

	"remoteagents/internal/api"
)

// RunAsUser determines the user for executing user-level commands.
func (p *stubPlatform) RunAsUser(cfg api.ControlCfg) (string, error) {
	if runAs := strings.TrimSpace(cfg.RunAs); runAs != "" {
		if _, err := user.Lookup(runAs); err != nil {
			return "", fmt.Errorf("platform: runas-user: invalid user %q: %w", runAs, err)
		}
		return runAs, nil
	}

	stateRunasPath := filepath.Join(p.DefaultHome(), "state", "runas")
	if data, err := os.ReadFile(stateRunasPath); err == nil {
		if uName := strings.TrimSpace(string(data)); uName != "" {
			if _, err := user.Lookup(uName); err == nil {
				return uName, nil
			}
		}
	}

	if sudoUser := strings.TrimSpace(os.Getenv("SUDO_USER")); sudoUser != "" && sudoUser != "root" {
		if _, err := user.Lookup(sudoUser); err == nil {
			return sudoUser, nil
		}
	}

	if u, err := user.Current(); err == nil && u.Username != "" && u.Username != "root" {
		return u.Username, nil
	}

	if os.Geteuid() == 0 {
		return "", errors.New("platform: runas-not-found: running as root without user in controlRunAs, state/runas or SUDO_USER")
	}

	return "", errors.New("platform: runas-not-found: unable to determine user")
}
