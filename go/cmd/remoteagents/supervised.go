package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"remoteagents/internal/api"
	"remoteagents/internal/core"
	"remoteagents/internal/supervise"
)

// runSupervised — общий запуск сторожа для ярлыка (`supervise`) и запуска без аргументов:
// значок в трее (после взятия блокировки единственного экземпляра), повторный запуск открывает страницу
// работающего экземпляра и выходит.
func runSupervised(ctx context.Context, p api.Paths, mode api.Mode, args []string) int {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	prevUI, prevLocked := supervise.OnUI, supervise.OnLocked
	var stopTray func()
	supervise.OnLocked = func() {
		if prevLocked != nil {
			prevLocked()
		}
		stopTray = startTray(ctx, p.Home, cancel)
	}
	supervise.OnUI = func(url string) {
		trayURL(url)
		if prevUI != nil {
			prevUI(url)
		}
	}
	code := supervise.Run(ctx, p, nil, nil, os.Args[0], mode, args)
	if stopTray != nil {
		stopTray()
	}
	if code == api.SupExitRunning {
		b, err := os.ReadFile(filepath.Join(p.State, core.UIURLFile))
		if err == nil {
			if url := strings.TrimSpace(string(b)); url != "" {
				fmt.Printf("Уже запущено, страница: %s\n", url)
				if openURL(url) == nil {
					return 0
				}
			}
		}
		msg := "RemoteAgents уже запущен, но адрес страницы неизвестен."
		fmt.Fprintln(os.Stderr, msg)
		showError(msg)
	}
	return code
}
