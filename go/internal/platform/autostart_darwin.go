//go:build darwin

package platform

import (
	"fmt"
	"path/filepath"
	"strings"

	"remoteagents/internal/api"
)

// Autostart возвращает спецификацию автозапуска через launchd plist (service_darwin.go).
func (p *stubPlatform) Autostart(binPath, home, inst8 string) api.AutostartSpec {
	label := "com.remoteagents3"
	if inst8 != "" {
		label = fmt.Sprintf("com.remoteagents3.%s", inst8)
	}
	plistPath := filepath.Join("/Library/LaunchDaemons", label+".plist")
	argsXML := "\t\t<string>" + escapeXML(binPath) + "</string>\n\t\t<string>supervise</string>\n"
	argsXML += "\t\t<string>--fallback</string>\n\t\t<string>" + escapeXML(binPath+".prev") + "</string>\n"
	if home != "" {
		argsXML += "\t\t<string>--home</string>\n\t\t<string>" + escapeXML(home) + "</string>\n"
	}
	plistContent := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>Label</key><string>%s</string>
<key>ProgramArguments</key><array>
%s</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict>
</plist>`, escapeXML(label), argsXML)
	return api.AutostartSpec{
		Kind:    "launchd",
		Path:    plistPath,
		Content: plistContent,
		Install: []string{"launchctl", "load", "-w", plistPath},
		Remove:  []string{"launchctl", "unload", "-w", plistPath},
		Enable:  []string{"launchctl", "enable", "system/" + label},
		Disable: []string{"launchctl", "disable", "system/" + label},
	}
}

func escapeXML(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;").Replace(s)
}
