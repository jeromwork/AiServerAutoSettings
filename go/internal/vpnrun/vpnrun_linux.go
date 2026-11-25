//go:build linux

package vpnrun

import (
	"context"
	"fmt"
	"time"

	"remoteagents/internal/api"
)

// Install: один раз sudo setcap (спросит пароль в терминале). Дальше root не нужен.
func (r *Runner) Install() error {
	if err := badPath(r.Sing, r.Conf); err != nil {
		return err
	}
	if _, err := run("sudo", "setcap", "cap_net_admin,cap_net_bind_service+ep", r.Sing); err != nil {
		return err
	}
	return nil
}

func (r *Runner) Uninstall() error {
	if r.Sing == "" {
		return nil
	}
	_, err := run("sudo", "setcap", "-r", r.Sing)
	return err
}

// Start: обычный ребёнок через procs (корзина, умрёт вместе с программой).
func (r *Runner) Start() error {
	if r.Running() {
		return nil
	}
	if r.Sing == "" || r.Conf == "" {
		return fmt.Errorf("vpnrun: not installed")
	}
	p, err := r.Procs.Start(context.Background(), api.ProcSpec{
		Name: "sing-box-vpn", Path: r.Sing, Args: []string{"run", "-c", r.Conf}, Stream: "vpn"})
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.proc = p
	r.mu.Unlock()
	return nil
}

func (r *Runner) Stop() error {
	r.mu.Lock()
	p := r.proc
	r.mu.Unlock()
	if p == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return p.Stop(ctx)
}

func (r *Runner) Running() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.proc == nil {
		return false
	}
	select {
	case <-r.proc.Done():
		return false
	default:
		return true
	}
}
