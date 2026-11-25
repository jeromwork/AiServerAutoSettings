//go:build windows

package platform

import (
	"fmt"
	"os/user"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// OpenBrowser uses the current desktop or the requested interactive user's token.
func (p *stubPlatform) OpenBrowser(url, runAs string) error {
	if !strings.HasPrefix(url, "http://") && !strings.HasPrefix(url, "https://") {
		return fmt.Errorf("platform: browser-url: expected HTTP(S) URL")
	}
	target, err := windows.UTF16PtrFromString(url)
	if err != nil {
		return fmt.Errorf("platform: browser-url: %w", err)
	}
	current, err := user.Current()
	if err != nil {
		return fmt.Errorf("platform: browser-user: %w", err)
	}
	if runAs == "" || strings.EqualFold(runAs, current.Username) || runAs == current.Uid {
		verb, err := windows.UTF16PtrFromString("open")
		if err != nil {
			return fmt.Errorf("platform: browser-verb: %w", err)
		}
		if err := windows.ShellExecute(0, verb, target, nil, nil, windows.SW_SHOWNORMAL); err != nil {
			return fmt.Errorf("platform: browser-open: %w", err)
		}
		return nil
	}
	requested, err := user.Lookup(runAs)
	if err != nil {
		return fmt.Errorf("platform: browser-user: %w", err)
	}
	var token windows.Token
	if err := windows.WTSQueryUserToken(windows.WTSGetActiveConsoleSessionId(), &token); err != nil {
		return fmt.Errorf("platform: browser-token: %w", err)
	}
	defer token.Close()
	owner, err := token.GetTokenUser()
	if err != nil {
		return fmt.Errorf("platform: browser-token-user: %w", err)
	}
	if !strings.EqualFold(owner.User.Sid.String(), requested.Uid) {
		return fmt.Errorf("platform: browser-session: requested user has no active console session")
	}
	systemDir, err := windows.GetSystemDirectory()
	if err != nil {
		return fmt.Errorf("platform: browser-system-dir: %w", err)
	}
	executable := filepath.Join(systemDir, "rundll32.exe")
	app, err := windows.UTF16PtrFromString(executable)
	if err != nil {
		return fmt.Errorf("platform: browser-executable: %w", err)
	}
	command, err := windows.UTF16PtrFromString(syscall.EscapeArg(executable) + " url.dll,FileProtocolHandler " + syscall.EscapeArg(url))
	if err != nil {
		return fmt.Errorf("platform: browser-command: %w", err)
	}
	desktop, err := windows.UTF16PtrFromString(`winsta0\default`)
	if err != nil {
		return fmt.Errorf("platform: browser-desktop: %w", err)
	}
	startup := windows.StartupInfo{Desktop: desktop}
	startup.Cb = uint32(unsafe.Sizeof(startup))
	var process windows.ProcessInformation
	if err := windows.CreateProcessAsUser(token, app, command, nil, nil, false, 0, nil, nil, &startup, &process); err != nil {
		return fmt.Errorf("platform: browser-open: %w", err)
	}
	defer windows.CloseHandle(process.Process)
	defer windows.CloseHandle(process.Thread)
	return nil
}
