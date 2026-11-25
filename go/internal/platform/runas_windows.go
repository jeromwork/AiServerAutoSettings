//go:build windows

package platform

import (
	"strings"

	"remoteagents/internal/api"
)

// RunAsUser determines the user for executing user-level commands.
func (p *stubPlatform) RunAsUser(cfg api.ControlCfg) (string, error) {
	if runAs := strings.TrimSpace(cfg.RunAs); runAs != "" {
		return runAs, nil
	}
	return "", nil
}
