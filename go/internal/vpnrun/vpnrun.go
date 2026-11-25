// Package vpnrun: VPN-sing-box (TUN) — единственный процесс, которому нужны права.
// Права выдаются один раз в Install (с паролем администратора), дальше Start/Stop/Running — без запросов.
package vpnrun

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/api"
)

const label = "ru.remoteagents.vpn" // служба (Mac) / задача (Windows)

// Runner: Install(singbox, config) — одноразово; Uninstall; Start; Stop; Running (методы — в файлах по ОС).
type Runner struct {
	Procs api.Procs // нужен только на Linux (запуск обычным ребёнком)
	Log   api.Logger
	Sing  string // путь к sing-box (Linux Start; на Win/Mac он уже записан в задачу/службу)
	Conf  string // путь к конфигу
	mu    sync.Mutex
	proc  api.Process
}

func run(name string, args ...string) ([]byte, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		err = fmt.Errorf("%s: %w: %s", name, err, strings.TrimSpace(string(out)))
	}
	return out, err
}

func badPath(ps ...string) error {
	for _, p := range ps {
		if p == "" || strings.ContainsAny(p, "\"'<>&\r\n$`") {
			return fmt.Errorf("vpnrun: unsupported path %q", p)
		}
	}
	return nil
}

// Watch — сторож как в v2: проверка раз в 3 с; упал — повтор через 60 с; 3 сбоя подряд — сдаёмся
// (пока не позовут Start вручную/не сбросят); 5 минут стабильной работы обнуляют счётчик.
// want() — нужен ли сейчас VPN (режим включён).
func (r *Runner) Watch(ctx context.Context, want func() bool) {
	const (
		check, retry, stable, maxFails = 3 * time.Second, 60 * time.Second, 5 * time.Minute, 3
	)
	var (
		wasUp   bool
		upSince time.Time
		next    time.Time
		fails   int
	)
	t := time.NewTicker(check)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		now := time.Now()
		if r.Running() {
			if !wasUp {
				wasUp, upSince = true, now
			}
			if fails > 0 && now.Sub(upSince) > stable {
				fails = 0
			}
			continue
		}
		if wasUp {
			wasUp = false
			if want() { // упал сам, а не остановлен нами
				fails++
				next = now.Add(retry)
				r.Log.Warn("vpn.down", "fails", fails)
			}
		}
		if !want() || fails >= maxFails || now.Before(next) {
			continue
		}
		if err := r.Start(); err != nil {
			fails++
			next = now.Add(retry)
			r.Log.Error("vpn.start", "err", err.Error(), "fails", fails)
			continue
		}
		wasUp, upSince = true, now
		r.Log.Info("vpn.started")
	}
}
