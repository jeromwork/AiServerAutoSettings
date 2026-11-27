//go:build linux

package platform

import (
	"context"

	"remoteagents/internal/api"
)

// SystemProxy — на Linux единого системного прокси нет: не определяется.
func SystemProxy() api.SysProxy { return api.SysProxy{} }

// WatchSysProxy — событий нет; канал закрывается с ctx.
func WatchSysProxy(ctx context.Context) <-chan struct{} {
	out := make(chan struct{})
	go func() { <-ctx.Done(); close(out) }()
	return out
}
