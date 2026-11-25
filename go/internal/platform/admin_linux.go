//go:build linux

package platform

// IsAdmin — заглушка до P5b.
func (p *stubPlatform) IsAdmin() bool { return false }
