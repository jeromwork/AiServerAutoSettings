package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"remoteagents/internal/api"
	"remoteagents/internal/core"
	"remoteagents/internal/platform"
	"remoteagents/internal/supervise"
)

// launch — запуск без аргументов (двойной щелчок): сторож + ядро, home по умолчанию,
// пока идёт разработка — режим --safe. Браузер открывается по сообщению ядра «ui».
func launch(ctx context.Context) int {
	plat := platform.Current()
	home := os.Getenv("REMOTEAGENTS_HOME")
	if home == "" {
		home = plat.DefaultHome()
	}
	if abs, err := filepath.Abs(home); err == nil {
		home = abs
	}
	p := api.NewPaths(home)
	for _, d := range []string{p.Home, p.State} {
		if err := os.MkdirAll(d, 0700); err != nil {
			fmt.Fprintf(os.Stderr, "Не удалось создать папку %s: %v\n", d, err)
			pause()
			return 2
		}
	}
	var once sync.Once
	supervise.OnUI = func(url string) {
		once.Do(func() {
			fmt.Printf("Запущено, страница: %s\n", url)
			if !hasConfig(p) {
				fmt.Println("Конфиг не задан — вставьте его на странице")
			}
			if err := openURL(url); err != nil {
				fmt.Printf("Откройте страницу вручную (браузер не открылся: %v)\n", err)
			}
		})
	}
	fmt.Println("Запускаю RemoteAgents (режим --safe)...")
	code := supervise.Run(ctx, p, nil, nil, os.Args[0], api.Mode{Safe: true}, []string{"--home", home})
	if code == api.SupExitRunning {
		b, err := os.ReadFile(filepath.Join(p.State, core.UIURLFile))
		if err == nil {
			url := strings.TrimSpace(string(b))
			fmt.Printf("Уже запущено, страница: %s\n", url)
			_ = openURL(url)
			return 0
		}
		fmt.Fprintln(os.Stderr, "Уже запущено, но адрес страницы неизвестен.")
	}
	if code != 0 && !errors.Is(ctx.Err(), context.Canceled) {
		fmt.Fprintf(os.Stderr, "Остановлено, код %d. Подробности — в журнале: %s\n", code, p.Logs)
		pause()
	}
	return code
}

// hasConfig — есть ли заданный конфиг в home.
func hasConfig(p api.Paths) bool {
	ents, err := os.ReadDir(p.Config)
	if err != nil {
		return false
	}
	for _, e := range ents {
		if e.Name() != "switch.json" {
			return true
		}
	}
	return false
}

// pause не даёт окну закрыться, пока человек не прочитал ошибку.
func pause() {
	fmt.Fprintln(os.Stderr, "Нажмите Enter, чтобы закрыть окно.")
	var b [1]byte
	_, _ = os.Stdin.Read(b[:])
}

// openURL открывает адрес в браузере по умолчанию (платформенная заглушка этого не умеет).
// Браузер не наш процесс: следов для уборки не нужно.
func openURL(url string) error {
	if !strings.HasPrefix(url, "http://") && !strings.HasPrefix(url, "https://") {
		return errors.New("ожидался адрес http(s)")
	}
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() { _ = cmd.Wait() }()
	return nil
}
