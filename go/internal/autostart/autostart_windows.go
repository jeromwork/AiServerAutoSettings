//go:build windows

package autostart

import (
	"fmt"
	"strings"
)

// Задача планировщика ONLOGON с обычными правами (LIMITED).
func Enable(exe string) error {
	if strings.ContainsAny(exe, "\"\r\n") {
		return fmt.Errorf("autostart: bad path")
	}
	return run("schtasks.exe", "/Create", "/TN", id, "/SC", "ONLOGON", "/RL", "LIMITED", "/F",
		"/TR", `"`+exe+`" --autostart`)
}

func Disable() error {
	if !Enabled() {
		return nil
	}
	return run("schtasks.exe", "/Delete", "/TN", id, "/F")
}

func Enabled() bool { return run("schtasks.exe", "/Query", "/TN", id) == nil }
