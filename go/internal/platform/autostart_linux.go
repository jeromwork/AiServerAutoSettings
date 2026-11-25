//go:build linux

package platform

import (
	"fmt"
	"path/filepath"
	"strings"

	"remoteagents/internal/api"
)

// Autostart возвращает спецификацию автозапуска через systemd unit (service_systemd_linux.go).
func (p *stubPlatform) Autostart(binPath, home, inst8 string) api.AutostartSpec {
	unitName := "remoteagents3.service"
	if inst8 != "" {
		unitName = fmt.Sprintf("remoteagents3-%s.service", inst8)
	}
	unitPath := filepath.Join("/etc/systemd/system", unitName)

	execStart := quoteSystemd(binPath) + " supervise --fallback " + quoteSystemd(binPath+".prev")
	if home != "" {
		execStart += " --home " + quoteSystemd(home)
	}

	content := strings.Join([]string{
		"[Unit]",
		"Description=RemoteAgents3 Service",
		"After=network.target",
		"",
		"[Service]",
		"Type=simple",
		"ExecStart=" + execStart,
		"Restart=on-failure",
		"RestartSec=5",
		"",
		"[Install]",
		"WantedBy=multi-user.target",
		"",
	}, "\n")

	return api.AutostartSpec{
		Kind:    "systemd",
		Path:    unitPath,
		Content: content,
		Install: []string{"systemctl", "enable", unitName},
		Remove:  []string{"systemctl", "disable", "--now", unitName},
		Enable:  []string{"systemctl", "enable", unitName},
		Disable: []string{"systemctl", "disable", unitName},
	}
}

// systemd expands specifiers and environment variables even in quoted arguments.
func quoteSystemd(s string) string {
	s = strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "%", "%%", "$", "$$", "\n", "\\n", "\r", "\\r", "\t", "\\t").Replace(s)
	return "\"" + s + "\""
}
