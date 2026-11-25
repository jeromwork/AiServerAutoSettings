//go:build darwin

package platform

import "os"

// IsAdmin reports whether the process has administrator (root) privileges.
func (p *stubPlatform) IsAdmin() bool {
	return os.Geteuid() == 0
}
