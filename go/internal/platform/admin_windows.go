//go:build windows

package platform

// IsAdmin — заглушка до P5b.
func (p *stubPlatform) IsAdmin() bool { return false }
