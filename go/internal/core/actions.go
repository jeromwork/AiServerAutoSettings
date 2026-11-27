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
	"remoteagents/internal/supervise"
	"remoteagents/internal/update"
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
		"version":     c.f.Version,
		"build":       c.f.Build,
		"pc":          c.pcName(),
		"name":        c.cfgName(),
		"connect":     c.connectInfo(),
		"uptime":      int(time.Since(c.start).Seconds()),
		"mode":        map[string]bool{"safe": c.f.Mode.Safe, "noTun": c.f.Mode.NoTun, "noChannel": c.f.Mode.NoChannel, "noSingbox": c.f.Mode.NoSingbox},
		"control":     c.control.Load(),
		"paused":      c.paused.Load(),
		"config":      c.cfg != nil,
		"gen":         c.gen,
		"prevVersion": supervise.ReadInfo(c.p).Previous,
	}
	if ch := c.getCh(); ch != nil {
		st := ch.State()
		st.Reason = sanitize(st.Reason)
		m["channel"] = st
	}
	if sb := c.getSb(); !isNil(sb) {
		st := sb.Status()
		if e, ok := st["binaryError"].(string); ok {
			st["binaryError"] = sanitize(e)
		}
		m["singbox"] = st
	}
	if c.tun != nil {
		m["vpn"] = c.tun.status()
	}
	if fw := c.getFw(); !isNil(fw) {
		m["forwards"] = fw.List()
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
// Ход работы идёт событиями "update" на страницу: проверяю / скачиваю / проверяю кандидата / запускаю / ошибка.
func (c *core) UpdateNow(ctx context.Context) error { return c.updateNow(ctx, true) }

func (c *core) updateNow(ctx context.Context, manual bool) (err error) {
	if c.upd == nil {
		c.publishUpdate("error", "Обновление недоступно в этой сборке (нет ключей выпуска).")
		return api.ErrNotSupported
	}
	unlock, err := c.lockOp()
	if err != nil {
		if manual {
			c.publishUpdate("error", c.explainApplyErr(err))
		}
		return err
	}
	defer unlock()
	defer func() {
		if errors.Is(err, update.ErrConfigRejected) {
			c.log.Warn("core: update-config-rejected", "err", err.Error())
			c.publishUpdate("warn", "Новая версия не подходит к вашему конфигу, остаёмся на текущей.")
			err = nil
			return
		}
		if err != nil && !errors.Is(err, api.ErrBusy) {
			c.publishUpdate("error", "Обновление не выполнено: "+sanitize(err.Error()))
		}
	}()
	if manual && c.isDevBuild() {
		c.publishUpdate("checking", "Внимание: это dev-сборка ("+c.f.Version+"), обновляю по вашей команде. Проверяю наличие новой версии...")
	} else if manual {
		c.publishUpdate("checking", "Проверяю наличие новой версии и подпись выпуска...")
	}
	r, err := c.UpdateCheck(ctx)
	if err != nil {
		return err
	}
	if r == nil {
		if manual {
			c.publishUpdate("uptodate", "Установлена последняя версия "+c.f.Version+".")
		}
		return nil
	}
	if !manual && supervise.ReadInfo(c.p).Bad == r.Version {
		c.log.Info("core: auto-update-skip-bad", "version", r.Version)
		return nil
	}
	c.publishUpdate("downloading", "Скачиваю версию "+r.Version+" и проверяю контрольную сумму...")
	cand, err := c.upd.Fetch(ctx, *r)
	if err != nil {
		return err
	}
	c.publishUpdate("verifying", "Проверяю кандидата: запуск и чтение текущего конфига...")
	if err := c.upd.Stage(ctx, cand, r.Version); err != nil {
		return err
	}
	c.log.Info("core: update-staged", "version", r.Version)
	c.markUpdating(r.Version)
	c.publishUpdate("restarting", "Запускаю версию "+r.Version+"; если она не подтвердит работу за 120 с — вернусь на "+c.f.Version+".")
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
	return c.validateConfig(data, password)
}

// ConfigApply: новый конфиг применяется перезапуском; сторож следит за switch.json (откат за ConfigSwitchSec).
func (c *core) ConfigApply(ctx context.Context, data []byte, password string) error {
	c.publishApply("applying", "Проверяю и записываю конфиг...")
	fail := func(err error) error {
		text := c.explainApplyErr(err)
		c.log.Warn("core: config-apply-failed", "text", text)
		c.publishApply("error", text)
		return errors.New(text)
	}
	if err := c.validateConfig(data, password); err != nil {
		return fail(err)
	}
	unlock, err := c.lockOp()
	if err != nil {
		return fail(err)
	}
	defer unlock()
	gen, err := config.Apply(c.p, data, password, c.log)
	if err != nil {
		return fail(err)
	}
	c.log.Info("core: config-applied", "gen", gen)
	c.publishApply("restarting", "Конфиг записан, перезапускаю программу и проверяю связь с сервером...")
	c.requestQuit(api.ExitRestart, nil)
	return nil
}

// ConfigExport: сохранённый конфиг как есть (ключи в нём зашифрованы паролем конфига).
func (c *core) ConfigExport() ([]byte, error) { return config.ExportCurrent(c.p) }

// ConfigSetVPN: меняет только vpn.mode сохранённого конфига и применяет тем же путём, что ConfigApply.
func (c *core) ConfigSetVPN(ctx context.Context, mode string) error {
	c.publishApply("applying", "Меняю режим VPN в конфиге...")
	fail := func(err error) error {
		text := c.explainApplyErr(err)
		c.log.Warn("core: config-vpn-failed", "text", text)
		c.publishApply("error", text)
		return errors.New(text)
	}
	if c.f.Mode.Safe {
		return fail(api.ErrSafe)
	}
	unlock, err := c.lockOp()
	if err != nil {
		return fail(err)
	}
	defer unlock()
	gen, err := config.SetVPNMode(c.p, mode, c.log)
	if err != nil {
		return fail(err)
	}
	c.log.Info("core: config-vpn-applied", "gen", gen, "mode", mode)
	c.publishApply("restarting", "Конфиг записан, перезапускаю программу и проверяю связь с сервером...")
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
	if ch := c.getCh(); ch != nil {
		return ch.ForcePath(name)
	}
	sb := c.getSb()
	if isNil(sb) {
		return api.ErrNotSupported
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return sb.Clash(ctx, "PUT", "/proxies/chan", map[string]string{"name": name}, nil)
}

// VPN: сменить режим на время работы (в конфиг не пишется); в --safe — ErrSafe.
func (c *core) VPN(mode string) error {
	if c.f.Mode.Safe {
		return api.ErrSafe
	}
	if c.tun == nil || c.cfg == nil || isNil(c.getSb()) {
		return api.ErrNotSupported
	}
	c.tun.setMode(context.Background(), mode)
	return nil
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
	ch := c.getCh()
	if ch == nil {
		return errors.New("core: log-send: channel-unavailable")
	}
	pc := c.pcName()
	if !pcNameRe.MatchString(pc) {
		return errors.New("core: log-send: bad-pc-name")
	}
	var out, errb bytes.Buffer
	code, err := ch.Exec(ctx, "~/.local/bin/ra-lab --pc "+pc+" collect --once", nil, &out, &errb)
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
	prev := supervise.ReadInfo(c.p).Previous
	if prev == "" || prev == c.f.Version {
		c.publishUpdate("error", "Предыдущей версии для возврата нет.")
		return supervise.ErrNoPrevious
	}
	unlock, err := c.lockOp()
	if err != nil {
		return err
	}
	defer unlock()
	c.publishUpdate("restarting", "Возвращаю прежнюю версию "+prev+"...")
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
