//go:build darwin

package autostart

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func plistPath() (string, error) {
	h, err := os.UserHomeDir()
	return filepath.Join(h, "Library", "LaunchAgents", id+".plist"), err
}

func domain() string { return fmt.Sprintf("gui/%d", os.Getuid()) }

// LaunchAgent пользователя: root не нужен.
func Enable(exe string) error {
	if strings.ContainsAny(exe, "<>&\"\r\n") {
		return fmt.Errorf("autostart: bad path")
	}
	p, err := plistPath()
	if err != nil {
		return err
	}
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>` + id + `</string>
<key>ProgramArguments</key><array><string>` + exe + `</string><string>--autostart</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
`
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(p, []byte(plist), 0o644); err != nil {
		return err
	}
	_ = run("launchctl", "bootout", domain()+"/"+id) // обновить, если уже была
	return run("launchctl", "bootstrap", domain(), p)
}

func Disable() error {
	p, err := plistPath()
	if err != nil {
		return err
	}
	_ = run("launchctl", "bootout", domain()+"/"+id)
	if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func Enabled() bool {
	p, err := plistPath()
	if err != nil {
		return false
	}
	_, err = os.Stat(p)
	return err == nil
}
