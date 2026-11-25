//go:build linux

package vpnrun

import (
	"context"
	"fmt"
	"os"
	"os/user"

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
	f, err := os.CreateTemp("", "ra-vpn-sudoers-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	u, err := user.Current()
	if err != nil {
		f.Close()
		return err
	}
	data := u.Username + " ALL=(root) NOPASSWD: /usr/bin/resolvectl default-route RA2-LAN no, /usr/bin/resolvectl dns RA2-LAN *, /usr/bin/resolvectl domain RA2-LAN *, /usr/bin/resolvectl revert RA2-LAN\n"
	if _, err = f.WriteString(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if _, err = run("sudo", "visudo", "-cf", f.Name()); err != nil {
		return err
	}
	_, err = run("sudo", "install", "-m", "440", "-o", "root", "-g", "root", f.Name(), "/etc/sudoers.d/ru-remoteagents-vpn-dns")
	return err
}

func (r *Runner) Uninstall() error {
	if err := r.ClearDNS(context.Background()); err != nil {
		return err
	}
	if _, err := run("sudo", "rm", "-f", "/etc/sudoers.d/ru-remoteagents-vpn-dns"); err != nil {
		return err
	}
	if r.Sing == "" {
		return nil
	}
	_, err := run("sudo", "setcap", "-r", r.Sing)
	return err
}

// start: обычный ребёнок через procs (корзина, умрёт вместе с программой).
func (r *Runner) start() error {
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

func (r *Runner) stop(ctx context.Context) error {
	r.mu.Lock()
	p := r.proc
	r.mu.Unlock()
	if p == nil {
		return nil
	}
	return p.Stop(ctx)
}

// exited: событие выхода процесса (канал из procs) — обрывает ожидание API, если sing-box умер при старте.
func (r *Runner) exited() <-chan struct{} {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.proc == nil {
		return nil
	}
	return r.proc.Done()
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
