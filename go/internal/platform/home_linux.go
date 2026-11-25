//go:build linux

package platform

// DefaultHome — заглушка до P5b.
func (p *stubPlatform) DefaultHome() string { return "" }
