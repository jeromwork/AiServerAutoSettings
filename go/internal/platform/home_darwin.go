//go:build darwin

package platform

// DefaultHome — заглушка до P5b.
func (p *stubPlatform) DefaultHome() string { return "" }
