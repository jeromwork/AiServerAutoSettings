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
		"version":           c.f.Version,
		"build":             c.f.Build,
		"pc":                c.pcName(),
		"name":              c.cfgName(),
		"connect":           c.connectInfo(),
		"uptime":            int(time.Since(c.start).Seconds()),
		"mode":              map[string]bool{"safe": c.f.Mode.Safe, "noTun": c.f.Mode.NoTun, "noChannel": c.f.Mode.NoChannel, "noSingbox": c.f.Mode.NoSingbox},
		"control":           c.control.Load(),
		"paused":            c.paused.Load(),
		"config":            c.cfg != nil,
		"channelConfigured": c.cfg == nil || c.cfg.HasChannel(),
		"gen":               c.gen,
		"prevVersion":       supervise.ReadInfo(c.p).Previous,
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
	m["counters"] = c.counters()
	if c.tun != nil {
		m["vpn"] = c.tun.status()
	}
	if sp := c.sysProxyStatus(); sp != nil {
		m["sysproxy"] = sp
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
	c.publishTrial()
	c.requestQuit(api.ExitRestart, nil)
	return nil
}

// ConfigExport: сохранённый конфиг как есть (ключи в нём зашифрованы паролем конфига).
func (c *core) ConfigExport() ([]byte, error) { return config.ExportCurrent(c.p) }

// ConfigSetVPN: меняет только vpn.mode сохранённого конфига и применяет тем же путём, что ConfigApply.
func (c *core) ConfigSetVPN(ctx context.Context, mode string) error {
	c.publishApply("applying", "Меняю режим VPN в конфиге...")
	if mode == "off" && c.tun != nil && c.cfg != nil && !c.f.Mode.Safe {
		// Выключение обязано сработать сразу и независимо от записи конфига (занятая операция, ошибка записи): снимаем VPN и блок на ходу.
		c.tun.setMode(context.WithoutCancel(ctx), "off")
	}
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
	if mode == "off" {
		if _, err := config.CancelTrial(c.p, c.log); err != nil { // выключение в пробном окне = откат к прежнему
			return fail(err)
		}
		c.publishTrial()
	}
	gen, err := config.SetVPNMode(c.p, mode, c.log)
	if err != nil {
		return fail(err)
	}
	c.log.Info("core: config-vpn-applied", "gen", gen, "mode", mode)
	if err := c.adoptVPNConfig(ctx); err != nil {
		return fail(err)
	}
	if c.tun != nil && c.cfg != nil && !c.f.Mode.Safe {
		c.tun.setMode(context.WithoutCancel(ctx), mode) // на ходу, без перезапуска программы
	}
	c.publishTrial()
	c.publishApply("ready", "Режим VPN изменён и сохранён в конфиге.")
	return nil
}

// ConfigSetVPNLock: меняет только vpn.lockExit сохранённого конфига и применяет тем же путём.
func (c *core) ConfigSetVPNLock(ctx context.Context, on bool) error {
	c.publishApply("applying", "Меняю галочку «выход только через наш адрес» в конфиге...")
	fail := func(err error) error {
		text := c.explainApplyErr(err)
		c.log.Warn("core: config-vpn-lock-failed", "text", text)
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
	if !on {
		// Снять галочку можно всегда, даже в пробном окне: откат к прежнему поколению; если в нём галочка уже выключена — больше ничего не нужно.
		if cancelled, err := config.CancelTrial(c.p, c.log); err != nil {
			return fail(err)
		} else if cancelled {
			c.publishTrial()
			if cfg, _, lerr := config.Load(c.p, c.log); lerr == nil && !cfg.VPN.LockExit {
				if err := c.adoptVPNConfig(ctx); err != nil {
					return fail(err)
				}
				c.reconcileLock(ctx)
				c.publishApply("rolledback", "Изменение отменено: "+config.ReasonUser)
				return nil
			}
		}
	}
	gen, err := config.SetVPNLock(c.p, on, c.log)
	if err != nil {
		return fail(err)
	}
	c.log.Info("core: config-vpn-lock-applied", "gen", gen, "lock", on)
	if err := c.adoptVPNConfig(ctx); err != nil {
		return fail(err)
	}
	c.reconcileLock(ctx)
	c.publishTrial()
	c.publishApply("ready", "Галочка «выход только через наш адрес» изменена и сохранена в конфиге.")
	return nil
}

// adoptVPNConfig: после записи нового поколения (меняется только vpn.mode/lockExit) принимает его без перезапуска:
// поколение сразу подтверждается (связь уже работает), в памяти обновляются gen и vpn-поля конфига.
func (c *core) adoptVPNConfig(ctx context.Context) error {
	cfg, gen, err := config.Load(c.p, c.log)
	if err != nil {
		return err
	}
	if ptr, e := config.ReadPointers(c.p); e == nil && ptr.Switch != nil && ptr.Switch.To == gen {
		if err := config.Commit(c.p, gen, time.Now()); err != nil {
			c.log.Warn("core: config-commit", "gen", gen, "err", err.Error())
		}
	}
	c.gen = gen
	if c.cfg != nil {
		if g := c.tun; g != nil {
			g.mu.Lock()
			defer g.mu.Unlock()
		}
		c.cfg.VPN.Mode, c.cfg.VPN.LockExit = cfg.VPN.Mode, cfg.VPN.LockExit
	}
	return nil
}

// reconcileLock применяет новое значение lockExit: снятая галочка снимает блок, затем пересчёт (pf/перекрытие/проверка выхода).
func (c *core) reconcileLock(ctx context.Context) {
	g := c.tun
	if g == nil || c.cfg == nil || c.f.Mode.Safe {
		return
	}
	if !g.lock() {
		g.blocked.Store(false)
	}
	g.reconcile(context.WithoutCancel(ctx), "vpn-lock")
}

// persistVPNMode сохраняет режим в конфиг (после выключения на ходу или после 3-й неудачи). Занятую запись не ждёт.
// cancelTrial: пробное окно откатывается (ручное выключение); иначе при окне ничего не пишем — им управляет откат.
func (c *core) persistVPNMode(mode string, cancelTrial bool) error {
	if c.f.Mode.Safe || c.cfg == nil {
		return nil
	}
	unlock, err := c.lockOp()
	if err != nil {
		return err
	}
	defer unlock()
	if ptr, e := config.ReadPointers(c.p); e == nil && ptr.Switch != nil {
		if !cancelTrial {
			return nil
		}
		if _, err := config.CancelTrial(c.p, c.log); err != nil {
			return err
		}
		c.publishTrial()
	}
	if cfg, _, err := config.Load(c.p, c.log); err == nil && cfg.VPN.Mode == mode {
		return nil
	}
	if _, err := config.SetVPNMode(c.p, mode, c.log); err != nil {
		c.log.Warn("core: vpn-mode-persist-failed", "mode", mode, "err", err.Error())
		return err
	}
	return c.adoptVPNConfig(context.Background())
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

// VPN: сменить режим на время работы (в конфиг пишется только off); в --safe — ErrSafe.
func (c *core) VPN(mode string) error {
	if c.f.Mode.Safe {
		return api.ErrSafe
	}
	if c.tun == nil || c.cfg == nil || (isNil(c.getSb()) && isNil(c.getVpnSb())) {
		return api.ErrNotSupported
	}
	c.tun.setMode(context.Background(), mode)
	if mode == "off" {
		go func() { _ = c.persistVPNMode("off", true) }() // выключение переживает перезапуск; быстрый путь не ждёт запись
	}
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

// counters — счётчики для /state: число ssh-сессий канала (норма 1, при переключении <= 2) и процессов sing-box (по 1).
func (c *core) counters() map[string]int {
	m := map[string]int{}
	if ch, ok := c.getCh().(interface{ Sessions() int }); ok {
		m["chanSessions"] = ch.Sessions()
	}
	if sb, ok := c.getSb().(interface{ Procs() int }); ok {
		m["singboxProcs"] = sb.Procs()
	}
	if sb, ok := c.getVpnSb().(interface{ Procs() int }); ok {
		m["vpnProcs"] = sb.Procs()
	}
	return m
}
