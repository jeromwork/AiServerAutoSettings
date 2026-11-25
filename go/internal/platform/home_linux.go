//go:build linux

package platform

// DefaultHome returns the default home directory on Linux.
func (p *stubPlatform) DefaultHome() string {
	return "/var/lib/remoteagents3"
}
