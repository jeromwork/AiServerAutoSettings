package platform

import (
	"context"
	"errors"
	"runtime"

	"remoteagents/internal/api"
)

func Current() api.Platform { return &stubPlatform{} }

func NewLANOps(log api.Logger, tr api.Traces, inst8 string) api.LANOps {
	return &stubLANOps{}
}

type stubPlatform struct{}

func (p *stubPlatform) OS() string   { return runtime.GOOS }
func (p *stubPlatform) Arch() string { return runtime.GOARCH }
func (p *stubPlatform) DefaultHome() string {
	return ""
}
func (p *stubPlatform) IsAdmin() bool { return false }
func (p *stubPlatform) RunAsUser(cfg api.ControlCfg) (string, error) {
	return "", errors.New("platform: not-implemented")
}
func (p *stubPlatform) NewShell(log api.Logger, pr api.Procs, runAs string) api.Shell {
	return stubShell{}
}
func (p *stubPlatform) OpenBrowser(url, runAs string) error {
	return errors.New("platform: not-implemented")
}
func (p *stubPlatform) Autostart(binPath, home, inst8 string) api.AutostartSpec {
	return api.AutostartSpec{}
}
func (p *stubPlatform) Interfaces() ([]api.Iface, error) {
	return nil, errors.New("platform: not-implemented")
}

type stubLANOps struct{}

func (l *stubLANOps) ApplyDomains(domains []string, dnsServer string) error {
	return api.ErrNotSupported
}
func (l *stubLANOps) RemoveAll() error { return api.ErrNotSupported }

type stubShell struct{}

func (stubShell) Start(context.Context, api.ExecReq) (api.ExecProc, error) {
	return nil, errors.New("shell: not-implemented")
}
func (stubShell) Get(string) (api.ExecProc, bool) { return nil, false }
func (stubShell) List() []api.ExecProc            { return nil }
func (stubShell) KillAll() error                  { return nil }
