//go:build darwin

package platform

import "remoteagents/internal/api"

func (p *stubPlatform) NewShell(log api.Logger, pr api.Procs, runAs string) api.Shell {
	return NewShell(log, pr, runAs)
}
