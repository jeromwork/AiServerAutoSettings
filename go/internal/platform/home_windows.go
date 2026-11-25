//go:build windows

package platform

import (
	"os"
	"path/filepath"
)

// DefaultHome returns the default home directory on Windows.
func (p *stubPlatform) DefaultHome() string {
	if local := os.Getenv("LOCALAPPDATA"); local != "" {
		return filepath.Join(local, "RemoteAgents3")
	}
	if userProfile := os.Getenv("USERPROFILE"); userProfile != "" {
		return filepath.Join(userProfile, "AppData", "Local", "RemoteAgents3")
	}
	return `C:\ProgramData\RemoteAgents3`
}
