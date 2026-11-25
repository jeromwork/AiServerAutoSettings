//go:build windows

package platform

import (
	"context"
	"errors"

	"remoteagents/internal/api"
)

// NewShell — заглушка до P5a.
func (p *stubPlatform) NewShell(log api.Logger, pr api.Procs, runAs string) api.Shell {
	return stubShell{}
}

type stubShell struct{}

func (stubShell) Start(context.Context, api.ExecReq) (api.ExecProc, error) {
	return nil, errors.New("shell: not-implemented")
}
func (stubShell) Get(string) (api.ExecProc, bool) { return nil, false }
func (stubShell) List() []api.ExecProc            { return nil }
func (stubShell) KillAll() error                  { return nil }
