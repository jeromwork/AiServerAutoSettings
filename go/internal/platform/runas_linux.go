//go:build linux

package platform

import (
	"errors"
	"fmt"
	"os"
	"os/user"
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

	// Integration requires the caller to load state/runas from its selected
	// home into cfg.RunAs. The current contract supplies neither that home nor
	// a state store; DefaultHome may belong to a different instance.
	if sudoUser := strings.TrimSpace(os.Getenv("SUDO_USER")); sudoUser != "" && sudoUser != "root" {
		if _, err := user.Lookup(sudoUser); err == nil {
			return sudoUser, nil
		}
	}

	if u, err := user.Current(); err == nil && u.Username != "" && u.Username != "root" {
		return u.Username, nil
	}

	if os.Geteuid() == 0 {
		return "", errors.New("platform: runas-not-found: running as root; supply controlRunAs or load the selected home state/runas into cfg.RunAs")
	}

	return "", errors.New("platform: runas-not-found: unable to determine user")
}
