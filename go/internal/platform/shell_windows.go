//go:build windows

package platform

import (
	"remoteagents/internal/agent"
	"remoteagents/internal/api"
)

func (nativePlatform) NewShell(log api.Logger, pr api.Procs) api.Shell {
	return agent.NewShell(log, pr)
}
