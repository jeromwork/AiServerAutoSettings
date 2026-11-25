//go:build windows

package platform

import "golang.org/x/sys/windows"

// IsAdmin reports whether the process has administrator privileges (elevated token).
func (p *stubPlatform) IsAdmin() bool {
	var token windows.Token
	err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY, &token)
	if err != nil {
		return false
	}
	defer token.Close()
	return token.IsElevated()
}
