//go:build darwin

package platform

import (
	"context"
	"os/exec"
	"time"

	"remoteagents/internal/api"
)

// SystemProxy — `scutil --proxy` (только чтение).
func SystemProxy() api.SysProxy {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/sbin/scutil", "--proxy").Output()
	if err != nil {
		return api.SysProxy{}
	}
	return parseScutilProxy(string(out))
}

// WatchSysProxy — отдельного события нет: на macOS пересчёт идёт по net-changed и по кнопке; канал закрывается с ctx.
func WatchSysProxy(ctx context.Context) <-chan struct{} {
	out := make(chan struct{})
	go func() { <-ctx.Done(); close(out) }()
	return out
}
