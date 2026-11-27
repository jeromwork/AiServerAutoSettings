package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/platform"
	"remoteagents/internal/supervise"
)

// launch — запуск без аргументов (двойной щелчок): то же, что ярлык `supervise --home <по умолчанию>`.
// Режим --safe — только по явному флагу `launch --safe` или если конфига ещё нет (применять нечего).
// Браузер открывается по сообщению ядра «ui».
func launch(ctx context.Context, args []string) (code int) {
	safeFlag := false
	for _, a := range args {
		if a == "--safe" || a == "-safe" {
			safeFlag = true
		}
	}
	plat := platform.Current()
	home := os.Getenv("REMOTEAGENTS_HOME")
	if home == "" {
		home = plat.DefaultHome()
	}
	if abs, err := filepath.Abs(home); err == nil {
		home = abs
	}
	p := api.NewPaths(home)
	logPath := openLaunchLog(p)
	// Паника лаунчера: запись в журнал и окно, консоль не закрывается молча.
	defer func() {
		if r := recover(); r != nil {
			msg := fmt.Sprintf("RemoteAgents: внутренняя ошибка запуска: %v\nЖурнал: %s", r, logPath)
			launchLog("panic: %v\n%s", r, debug.Stack())
			fmt.Fprintln(os.Stderr, msg)
			showError(msg)
			pause()
			code = 2
		}
	}()
	for _, d := range []string{p.Home, p.State} {
		if err := os.MkdirAll(d, 0700); err != nil {
			msg := fmt.Sprintf("Не удалось создать папку %s: %v", d, err)
			logPath = openLaunchLog(p)
			launchLog("%s", msg)
			fmt.Fprintln(os.Stderr, msg)
			showError(msg + "\nЖурнал: " + logPath)
			pause()
			return 2
		}
	}
	var once sync.Once
	prevUI := supervise.OnUI
	supervise.OnUI = func(url string) {
		if prevUI != nil {
			prevUI(url)
		}
		once.Do(func() {
			if !hasConfig(p) {
				fmt.Println("Конфиг не задан — вставьте его на странице")
			}
			if err := openURL(url); err != nil {
				fmt.Printf("Откройте страницу вручную (браузер не открылся: %v)\n", err)
			}
		})
	}
	mode := api.Mode{Safe: safeFlag || !hasConfig(p)}
	runArgs := []string{"--home", home, "--reset"}
	if mode.Safe {
		fmt.Println("Запускаю RemoteAgents (режим --safe)...")
	} else {
		fmt.Println("Запускаю RemoteAgents...")
	}
	code = runSupervised(ctx, p, mode, runArgs)
	if errors.Is(ctx.Err(), context.Canceled) {
		return code
	}
	if code != 0 {
		msg := fmt.Sprintf("RemoteAgents остановлен (код %d).\nЖурнал: %s", code, p.Logs+"\nлаунчер: "+logPath)
		launchLog("%s", msg)
		fmt.Fprintln(os.Stderr, msg)
		showError(msg)
		pause()
		return code
	}
	// Сторож может выйти с кодом 0, остановив ядро после серии падений.
	if why := stoppedReason(p); why != "" {
		msg := fmt.Sprintf("RemoteAgents не запустился: сторож остановил ядро (%s).\nЖурнал: %s", why, p.Logs+"\nлаунчер: "+logPath)
		launchLog("%s", msg)
		fmt.Fprintln(os.Stderr, msg)
		showError(msg)
		pause()
		return 1
	}
	return code
}

// stoppedReason — причина остановки из versions/state.json ("" если не остановлен).
func stoppedReason(p api.Paths) string {
	b, err := os.ReadFile(filepath.Join(p.Versions, "state.json"))
	if err != nil {
		return ""
	}
	var st struct {
		Stopped string `json:"stopped"`
	}
	if json.Unmarshal(b, &st) != nil {
		return ""
	}
	return st.Stopped
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

var (
	launchMu   sync.Mutex
	launchFile *os.File
)

// openLaunchLog открывает launcher.log: home\logs, иначе рядом с exe, иначе %TEMP%.
// Возвращает путь, куда реально пишем (""— нигде).
func openLaunchLog(p api.Paths) string {
	launchMu.Lock()
	defer launchMu.Unlock()
	if launchFile != nil {
		return launchFile.Name()
	}
	var dirs []string
	dirs = append(dirs, p.Logs)
	if exe, err := os.Executable(); err == nil {
		dirs = append(dirs, filepath.Dir(exe))
	}
	dirs = append(dirs, os.TempDir())
	for _, d := range dirs {
		if os.MkdirAll(d, 0700) != nil {
			continue
		}
		f, err := os.OpenFile(filepath.Join(d, "launcher.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
		if err == nil {
			launchFile = f
			return f.Name()
		}
	}
	return ""
}

// launchLog пишет строку в launcher.log (если он открыт).
func launchLog(format string, a ...any) {
	launchMu.Lock()
	defer launchMu.Unlock()
	if launchFile != nil {
		fmt.Fprintf(launchFile, "%s %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, a...))
	}
}
