//go:build windows

package platform

import "remoteagents/internal/api"

// NewLANOps — заглушка до N2.
func NewLANOps(log api.Logger, tr api.Traces, inst8 string) api.LANOps {
	return &stubLANOps{}
}

type stubLANOps struct{}

func (l *stubLANOps) ApplyDomains(domains []string, dnsServer string) error {
	return api.ErrNotSupported
}
func (l *stubLANOps) RemoveAll() error { return api.ErrNotSupported }
