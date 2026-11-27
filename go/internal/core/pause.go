package core

import (
	"context"
	"os"
	"path/filepath"
	"time"

	"remoteagents/internal/api"
)

// publishPause — событие страницы (SSE "pause") и строка журнала: stage = start|step|done|error.
func (c *core) pauseEvent(action, stage string, kv ...any) {
	name := action + "." + stage // pause.start, pause.step, pause.done, resume.start ...
	c.log.Info(name, kv...)
	m := map[string]any{"action": action, "stage": stage, "paused": c.paused.Load(), "at": time.Now().Format("15:04:05")}
	for i := 0; i+1 < len(kv); i += 2 {
		if k, ok := kv[i].(string); ok {
			m[k] = kv[i+1]
		}
	}
	c.publish("pause", m)
}

func (c *core) pauseFilePath() string { return filepath.Join(c.p.State, api.PauseFile) }

// Pause: останавливает всё сетевое (sing-box, TUN VPN/ЛВС, канал, forward, агент, процессы) и убирает следы как при выходе.
// Страница, сторож и журнал живут. Пауза записана в State/paused: ядро, упавшее на паузе, поднимается без сети;
// новый запуск программы (сторож) файл удаляет — пауза снята.
func (c *core) Pause(ctx context.Context) error {
	if c.cfg == nil || c.pr == nil {
		return api.ErrNotSupported
	}
	if !c.pauseMu.TryLock() {
		return api.ErrBusy
	}
	defer c.pauseMu.Unlock()
	if c.paused.Load() {
		return nil
	}
	begin := time.Now()
	c.pauseEvent("pause", "start")
	c.paused.Store(true)
	if err := os.WriteFile(c.pauseFilePath(), []byte("1\n"), 0600); err != nil {
		c.log.Warn("pause.state-write", "err", err.Error())
	}
	c.publishStatus()

	if c.netCancel != nil {
		c.netCancel() // гасит запуск сети, watchNet, watchChannel, tunGuard
	}
	c.waitNetDone()
	c.pauseEvent("pause", "step", "step", "network-start-cancelled")
	if g := c.tun; g != nil {
		g.mu.Lock()
		if g.retry != nil {
			g.retry.Stop()
		}
		g.mu.Unlock()
	}
	c.stopNetwork(func(name string, err error) {
		if err != nil {
			c.pauseEvent("pause", "step", "step", "stop-"+name, "err", sanitize(err.Error()))
		} else {
			c.pauseEvent("pause", "step", "step", "stop-"+name)
		}
	})
	c.compMu.Lock()
	c.ch, c.sb, c.fw, c.ag = nil, nil, nil, nil
	c.compMu.Unlock()
	if g := c.tun; g != nil {
		g.mu.Lock()
		g.vpnState, g.vpnWhy, g.lanState, g.lanWhy, g.fails = "off", "", "off", "", 0
		g.snap.Store(g.statusLocked())
		g.mu.Unlock()
	}
	c.pauseEvent("pause", "done", "ms", time.Since(begin).Milliseconds())
	c.publishStatus()
	return nil
}

// Resume: поднимает сеть заново по текущему конфигу (тот же путь, что и при старте).
func (c *core) Resume(ctx context.Context) error {
	if c.cfg == nil || c.pr == nil {
		return api.ErrNotSupported
	}
	if !c.pauseMu.TryLock() {
		return api.ErrBusy
	}
	defer c.pauseMu.Unlock()
	if !c.paused.Load() {
		return nil
	}
	begin := time.Now()
	c.pauseEvent("resume", "start")
	c.paused.Store(false)
	_ = os.Remove(c.pauseFilePath())
	c.clearLastErr()
	c.startNet(c.runCtx)
	c.pauseEvent("resume", "step", "step", "network-starting")
	c.pauseEvent("resume", "done", "ms", time.Since(begin).Milliseconds())
	c.publishStatus()
	return nil
}
