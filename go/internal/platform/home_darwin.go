//go:build darwin

package platform

// DefaultHome returns the default home directory on Darwin.
func (p *stubPlatform) DefaultHome() string {
	return "/Library/Application Support/RemoteAgents3"
}
