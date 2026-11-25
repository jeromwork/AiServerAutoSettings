//go:build darwin

package platform

import (
	"errors"

	"remoteagents/internal/api"
)

// RunAsUser — заглушка до P5b.
func (p *stubPlatform) RunAsUser(cfg api.ControlCfg) (string, error) {
	return "", errors.New("platform: not-implemented")
}
