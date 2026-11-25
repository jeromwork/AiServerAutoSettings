//go:build darwin

package platform

import (
	"errors"

	"remoteagents/internal/api"
)

// Interfaces — заглушка до N4.
func (p *stubPlatform) Interfaces() ([]api.Iface, error) {
	return nil, errors.New("platform: not-implemented")
}
