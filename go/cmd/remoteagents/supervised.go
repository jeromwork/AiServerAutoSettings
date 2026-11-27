package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"remoteagents/internal/api"
	"remoteagents/internal/core"
	"remoteagents/internal/install"
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
	self := os.Args[0]
	if abs, err := exec.LookPath(self); err == nil {
		self = abs
	}
	// Запущены не с постоянного пути, а там лежит более новый сторож — стартуем его (событие — в журнал запуска).
	if !install.Skip(version) && os.Getenv("RA_REDIRECTED") != "1" {
		if perm := install.RedirectTarget(p, self, version); perm != "" {
			launchLog("запуск перенаправлен на постоянный путь %s", perm)
			if err := spawnSupervisor(perm, mode, args); err == nil {
				return 0
			}
			launchLog("перенаправление не удалось, работаю с текущего exe")
		}
	}
	if !install.Skip(version) {
		supervise.OnStart = func(log api.Logger) {
			go install.Ensure(p, log, self, version)
		}
		supervise.Handover = true
	}
	code := supervise.Run(ctx, p, nil, nil, os.Args[0], mode, args)
	if code == api.SupExitHandover {
		if stopTray != nil {
			stopTray()
			stopTray = nil
		}
		perm := supervise.InstalledPath(p)
		launchLog("сторож переходит на новую версию: %s", perm)
		if err := spawnSupervisor(perm, mode, args); err != nil {
			launchLog("переход не удался: %v", err)
			showError("RemoteAgents обновился, но новый сторож не запустился: " + err.Error() + "\nЗапустите ярлык вручную.")
			return 1
		}
		return 0
	}
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

// supervisorArgs — аргументы нового сторожа: те же, что у текущего, плюс режим.
func supervisorArgs(mode api.Mode, args []string) []string {
	out := append([]string{"supervise"}, args...)
	if mode.Safe {
		out = append(out, "--safe")
	}
	if mode.NoTun {
		out = append(out, "--no-tun")
	}
	if mode.NoChannel {
		out = append(out, "--no-channel")
	}
	if mode.NoSingbox {
		out = append(out, "--no-singbox")
	}
	return out
}
