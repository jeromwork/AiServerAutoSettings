//go:build windows

package platform

import "remoteagents/internal/api"

// Autostart — заглушка до P5c.
func (p *stubPlatform) Autostart(binPath, home, inst8 string) api.AutostartSpec {
	return api.AutostartSpec{}
}
