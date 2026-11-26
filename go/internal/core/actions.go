package core

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"path/filepath"
	"regexp"
	"strconv"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/config"
)

var _ api.Actions = (*core)(nil)

var pcNameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

// lockOp — одна операция записи за раз: мьютекс процесса + файл LockOp (сторож/ra3 ждут его же).
func (c *core) lockOp() (func(), error) {
	if !c.opMu.TryLock() {
		return nil, api.ErrBusy
	}
	unlock, err := lockFile(filepath.Join(c.p.State, api.LockOp))
	if err != nil {
		c.opMu.Unlock()
		return nil, err
	}
	return func() { unlock(); c.opMu.Unlock() }, nil
}

func (c *core) Status() map[string]any {
	m := map[string]any{
		"version": c.f.Version,
		"build":   c.f.Build,
		"pc":      c.pcName(),
		"name":    c.cfgName(),
		"connect": c.connectInfo(),
		"uptime":  int(time.Since(c.start).Seconds()),
		"mode":    map[string]bool{"safe": c.f.Mode.Safe, "noTun": c.f.Mode.NoTun, "noChannel": c.f.Mode.NoChannel, "noSingbox": c.f.Mode.NoSingbox},
		"control": c.control.Load(),
		"config":  c.cfg != nil,
		"gen":     c.gen,
	}
	if c.ch != nil {
		m["channel"] = c.ch.State()
	}
	if !isNil(c.sb) {
		m["singbox"] = c.sb.Status()
	}
	if !isNil(c.fw) {
		m["forwards"] = c.fw.List()
	}
	if c.ui != nil {
		m["webui"] = c.ui.Status()
	}
	return m
}

func (c *core) UpdateCheck(ctx context.Context) (*api.Release, error) {
	if c.upd == nil {
		return nil, api.ErrNotSupported
	}
	r, err := c.upd.Check(ctx)
	if err != nil || r == nil {
		return nil, err
	}
	if r.Build <= c.build() {
		return nil, nil // новее нет
	}
	return r, nil
}

// UpdateNow: проверка → загрузка → слот (pending.json) → перезапуск; сторож запускает новый слот.
func (c *core) UpdateNow(ctx context.Context) error {
	if c.upd == nil {
		return api.ErrNotSupported
	}
	unlock, err := c.lockOp()
	if err != nil {
		return err
	}
	defer unlock()
	r, err := c.UpdateCheck(ctx)
	if err != nil || r == nil {
		return err
	}
	cand, err := c.upd.Fetch(ctx, *r)
	if err != nil {
		return err
	}
	if err := c.upd.Stage(ctx, cand, r.Version); err != nil {
		return err
	}
	c.log.Info("core: update-staged", "version", r.Version)
	c.requestQuit(api.ExitRestart, nil)
	return nil
}

func (c *core) InstallDev(ctx context.Context, body io.Reader, sha256, version string) error {
	if c.upd == nil {
		return api.ErrNotSupported
	}
	unlock, err := c.lockOp()
	if err != nil {
		return err
	}
	defer unlock()
	cand, err := c.upd.ReceiveDev(ctx, body, sha256, version)
	if err != nil {
		return err
	}
	if err := c.upd.Stage(ctx, cand, version); err != nil {
		return err
	}
	c.log.Info("core: dev-staged", "version", version)
	c.requestQuit(api.ExitRestart, nil)
	return nil
}

func (c *core) ConfigCheck(data []byte, password string) error {
	_, _, err := config.Open(data, password)
	return err
}

// ConfigApply: новый конфиг применяется перезапуском; сторож следит за switch.json (откат за ConfigSwitchSec).
func (c *core) ConfigApply(ctx context.Context, data []byte, password string) error {
	unlock, err := c.lockOp()
	if err != nil {
		return err
	}
	defer unlock()
	gen, err := config.Apply(c.p, data, password, c.log)
	if err != nil {
		return err
	}
	c.log.Info("core: config-applied", "gen", gen)
	c.requestQuit(api.ExitRestart, nil)
	return nil
}

func (c *core) ConfigRevert(ctx context.Context) error {
	unlock, err := c.lockOp()
	if err != nil {
		return err
	}
	defer unlock()
	if err := config.Revert(c.p, c.log); err != nil {
		return err
	}
	c.requestQuit(api.ExitRestart, nil)
	return nil
}

func (c *core) SetControl(on bool) error {
	c.control.Store(on)
	c.log.Info("core: control", "on", on)
	return nil
}

// SwitchPath: с каналом — ForcePath (selector + закрепление + переподключение); без канала — прямой PUT в Clash.
func (c *core) SwitchPath(name string) error {
	if c.ch != nil {
		return c.ch.ForcePath(name)
	}
	if isNil(c.sb) {
		return api.ErrNotSupported
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return c.sb.Clash(ctx, "PUT", "/proxies/chan", map[string]string{"name": name}, nil)
}

// VPN: до N1b (vpnguard) — ErrNotSupported; в --safe — ErrSafe.
func (c *core) VPN(mode string) error {
	if c.f.Mode.Safe {
		return api.ErrSafe
	}
	return api.ErrNotSupported
}

func (c *core) HappierURL() (string, error) {
	if c.cfg == nil || c.cfg.Happier.LocalWeb == nil || !c.cfg.Happier.LocalWeb.Enabled {
		return "", api.ErrNotSupported
	}
	u := url.URL{Scheme: "http", Host: "localhost:" + strconv.Itoa(c.cfg.Happier.LocalWeb.Port)}
	return u.String(), nil
}

func (c *core) LogTail(n int) []string { return c.jr.Tail(n) }
func (c *core) LogZip(w io.Writer) error {
	return c.jr.Zip(w)
}

func (c *core) LogSend(ctx context.Context) error {
	if c.ch == nil {
		return errors.New("core: log-send: channel-unavailable")
	}
	pc := c.pcName()
	if !pcNameRe.MatchString(pc) {
		return errors.New("core: log-send: bad-pc-name")
	}
	var out, errb bytes.Buffer
	code, err := c.ch.Exec(ctx, "~/.local/bin/ra-lab --pc "+pc+" collect --once", nil, &out, &errb)
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("core: log-send: exit %d: %s", code, bytes.TrimSpace(errb.Bytes()))
	}
	return nil
}

func (c *core) Leftovers(ctx context.Context) ([]string, error) {
	return c.clean.Check(ctx), nil
}

func (c *core) Restart(ctx context.Context) error {
	c.requestQuit(api.ExitRestart, nil)
	return nil
}

// Rollback: сообщение сторожу + выход 3; сторож выбирает слот по таблице §5.3.
func (c *core) Rollback(ctx context.Context, reason string) error {
	unlock, err := c.lockOp()
	if err != nil {
		return err
	}
	defer unlock()
	c.requestQuit(api.ExitRestart, map[string]any{"t": api.MsgRollback, "reason": reason})
	return nil
}

func (c *core) Exit(ctx context.Context) error {
	c.requestQuit(api.ExitOK, map[string]any{"t": api.MsgExit, "final": true})
	return nil
}

func (c *core) cfgName() string {
	if c.cfg != nil {
		return c.cfg.Name
	}
	return ""
}
