// Package cleanup (P10): уборка собственных следов при старте и выходе — как v2 cleanup.py.
// Данные программы и Диск сохраняются. Run убирает, Check только перечисляет, что осталось.
package cleanup

import (
	"context"
	"path/filepath"
	"time"

	"remoteagents/internal/api"
)

// VPNIface — имя нашего TUN-интерфейса VPN (v2 vpn.py OWN_IFACES); его хвост после жёсткого убийства снимает уборка.
const VPNIface = "RA2-VPN"
const LANIface = "RA2-LAN"

type Cleaner struct {
	home    string
	log     api.Logger
	reading bool
	ctx     context.Context
	issues  []string
}

func New(p api.Paths, log api.Logger) (*Cleaner, error) {
	home := filepath.Clean(p.Home)
	if home == filepath.VolumeName(home)+string(filepath.Separator) || home == "." {
		return nil, errNoHome
	}
	return &Cleaner{home: home, log: log}, nil
}

// Run: mode "startup" (до подъёма сети) или "exit". Возвращает шаги, которые не удались.
func (c *Cleaner) Run(ctx context.Context, mode string) []string { return c.perform(ctx, mode, false) }

// Check: перечислить оставшиеся следы, ничего не меняя.
func (c *Cleaner) Check(ctx context.Context) []string { return c.perform(ctx, "exit", true) }

type step struct {
	name string
	fn   func() error
}

func (c *Cleaner) perform(ctx context.Context, mode string, reading bool) []string {
	if mode != "startup" && mode != "exit" {
		return []string{"неизвестный режим уборки"}
	}
	limit := 59 * time.Second // §5б: это предел одного запуска уборки, а не опрос
	if mode == "exit" {
		limit = 28 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	w := &Cleaner{home: c.home, log: c.log, reading: reading, ctx: ctx}
	for _, s := range w.steps(mode) {
		if err := ctx.Err(); err != nil {
			w.note(s.name + ": не удалось выполнить (время уборки истекло)")
			continue
		}
		if err := s.fn(); err != nil {
			w.note(s.name + ": не удалось выполнить (" + err.Error() + ")")
		}
	}
	return w.issues
}

func (c *Cleaner) note(text string) {
	for _, s := range c.issues {
		if s == text {
			return
		}
	}
	c.issues = append(c.issues, text)
	if c.log != nil {
		c.log.Warn("cleanup", "msg", text)
	}
}
