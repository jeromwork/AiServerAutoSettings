// Package core — сборка ядра: порядок старта (§10 плана), обратная остановка, api.Actions.
package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode"

	"remoteagents/internal/agent"
	"remoteagents/internal/api"
	"remoteagents/internal/channel"
	"remoteagents/internal/cleanup"
	"remoteagents/internal/config"
	"remoteagents/internal/forward"
	"remoteagents/internal/journal"
	"remoteagents/internal/platform"
	"remoteagents/internal/procs"
	"remoteagents/internal/singbox"
	"remoteagents/internal/update"
	"remoteagents/internal/webui"
)

type Flags struct {
	Home, Config, PasswordFile, PC, DevAssets, Pprof, RollbackReason, ReleaseBase string
	Mode                                                                          api.Mode
	ExitAfter                                                                     time.Duration
	// Задаются main из -ldflags.
	Version, Build, Repo string
	Signers              []string
}

const (
	aliveEvery      = 10 * time.Second // протокол сторожа (§5.3), не опрос
	healthEvery     = 60 * time.Second // строка health (§2)
	updateFirst     = 10 * time.Minute
	updateEvery     = 6 * time.Hour
	stopStepTimeout = 10 * time.Second
)

// UIURLFile — файл в State с адресом страницы (для `remoteagents open`); удаляется при выходе.
const UIURLFile = "webui.url"

type quitReq struct {
	code int
	msg  map[string]any
}

type core struct {
	f     Flags
	p     api.Paths
	log   api.Logger
	jr    *journal.Journal
	plat  api.Platform
	clean *cleanup.Cleaner
	start time.Time

	cfg *api.Config
	gen string

	pr  api.Procs
	sh  api.Shell
	sb  api.Singbox
	ag  *agent.Agent
	ch  api.Channel
	fw  api.Forwarder
	ui  *webui.UI
	upd api.Updater

	control atomic.Bool

	// Ошибка запуска сети (понятный текст для страницы) и признак «первый up уже был».
	failed  atomic.Bool
	upOnce  atomic.Bool
	errMu   sync.Mutex
	lastErr string
	opMu    sync.Mutex // UpdateNow, ConfigApply и прочие записи — одна за раз (+ LockOp между процессами)

	compMu  sync.RWMutex // ch/sb/fw/ag пишет startNetwork (в своей горутине), читают страница и агент
	ev      events
	netDone chan struct{}

	onStop   []func()
	outMu    sync.Mutex
	goodOnce sync.Once
	quitOnce sync.Once
	quit     chan quitReq
}

// Run — ядро целиком. Код выхода: 0 — выход, 3 — перезапуск/новый слот (api.Exit*).
func Run(ctx context.Context, f Flags) int {
	plat := platform.Current()
	if f.Home == "" {
		f.Home = plat.DefaultHome()
	}
	if f.Home == "" {
		fmt.Fprintln(os.Stderr, "core: home: not set")
		return 2
	}
	if abs, err := filepath.Abs(f.Home); err == nil {
		f.Home = abs
	}
	p := api.NewPaths(f.Home)
	for _, d := range []string{p.Home, p.Config, p.State, p.Logs, p.Tmp, p.Bin, p.Versions} {
		if err := os.MkdirAll(d, 0700); err != nil {
			fmt.Fprintf(os.Stderr, "core: mkdir %s: %v\n", d, err)
			return 2
		}
	}

	// 1. Журнал: до открытия основного — boot-журнал; затем New(core).
	boot := journal.Boot(f.Home)
	jr, err := journal.New(p, api.StreamCore, journal.Options{MaxBytes: 5 << 20, Keep: 4})
	if err != nil {
		boot.Error("core: journal", "err", err.Error())
		fmt.Fprintf(os.Stderr, "core: journal: %v\n", err)
		return 2
	}
	defer func() { _ = jr.Close() }()
	log := api.Logger(jr.With("core"))

	// Один живой экземпляр на home. Берём ДО уборки, чтобы уборка не тронула живого соседа;
	// после аварии ОС уже отпустила блокировку.
	unlockCore, err := lockFile(filepath.Join(p.State, api.LockCore))
	if err != nil {
		log.Error("core: already-running", "err", err.Error())
		fmt.Fprintf(os.Stderr, "core: already-running: %v\n", err)
		return 2
	}
	defer unlockCore()

	c := &core{f: f, p: p, log: log, jr: jr, plat: plat, start: time.Now(), quit: make(chan quitReq, 1)}
	c.ev.kick = make(chan struct{}, 1)
	log.Info("core: start", "version", f.Version, "pid", os.Getpid(), "safe", f.Mode.Safe, "noTun", f.Mode.NoTun,
		"noChannel", f.Mode.NoChannel, "noSingbox", f.Mode.NoSingbox, "rollback", f.RollbackReason)

	// 2. Уборка остатков всех прошлых запусков — до запуска любых служб.
	clean, err := cleanup.New(p, log, plat)
	if err != nil {
		log.Error("core: cleanup-init", "err", err.Error())
		fmt.Fprintf(os.Stderr, "core: cleanup: %v\n", err)
		return 2
	}
	c.clean = clean
	for _, issue := range clean.Run(ctx, "startup") {
		log.Warn("core: cleanup-startup", "issue", issue)
	}

	sctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	runCtx, cancel := context.WithCancel(sctx)
	defer cancel()

	c.control.Store(true)
	c.startComponents(runCtx)

	// 11. health, 12. сигналы сторожу.
	bg := sync.WaitGroup{}
	bg.Add(2)
	go func() { defer bg.Done(); c.healthLoop(runCtx) }()
	go func() { defer bg.Done(); c.aliveLoop(runCtx) }()
	if c.netDone == nil {
		// Нет сети (нет конфига / сбой procs): ждать «up» нечего, версия жива, когда страница поднята.
		c.sendGood()
	}
	go c.pathsLoop(runCtx)
	if f.Pprof != "" {
		c.startPprof(f.Pprof)
	}

	var exitAfter <-chan time.Time
	if f.ExitAfter > 0 {
		t := time.NewTimer(f.ExitAfter)
		defer t.Stop()
		exitAfter = t.C
	}
	var req quitReq
	select {
	case req = <-c.quit:
	case <-sctx.Done():
		req = quitReq{0, map[string]any{"t": api.MsgExit, "final": true}}
	case <-exitAfter:
		req = quitReq{0, map[string]any{"t": api.MsgExit, "final": true}}
	}
	log.Info("core: stopping", "code", req.code)
	cancel()
	bg.Wait()
	c.stopComponents()
	if req.msg != nil {
		c.emit(req.msg)
	}
	log.Info("core: stopped", "code", req.code)
	return req.code
}

// requestQuit — первая заявка выигрывает.
func (c *core) requestQuit(code int, msg map[string]any) {
	c.quitOnce.Do(func() { c.quit <- quitReq{code, msg} })
}

// emit — единственное место, пишущее в stdout ядра (только JSON-строки).
func (c *core) emit(m map[string]any) {
	b, err := json.Marshal(m)
	if err != nil {
		return
	}
	c.outMu.Lock()
	defer c.outMu.Unlock()
	_, _ = os.Stdout.Write(append(b, '\n'))
}

func (c *core) sendGood() {
	c.goodOnce.Do(func() {
		c.emit(map[string]any{"t": api.MsgGood, "version": c.f.Version})
		c.log.Info("core: good", "version", c.f.Version)
	})
}

func (c *core) startComponents(ctx context.Context) {
	f, log := c.f, c.log

	c.loadLastErr()

	// 3. Конфиг. Нет конфига — только страница.
	var err error
	if f.Config != "" {
		c.cfg, err = config.LoadFile(f.Config, f.PasswordFile, log)
	} else {
		c.cfg, c.gen, err = config.Load(c.p, log)
	}
	if err != nil || c.cfg == nil {
		log.Warn("core: no-config, page only", "err", fmt.Sprint(err))
		c.cfg = nil
	}
	if c.cfg != nil {
		c.control.Store(c.cfg.Control.Enabled)
	}

	// Обновление нужно и странице без конфига (Repo/ключи из сборки).
	c.upd, err = update.New(c.p, log, update.Options{Repo: f.Repo, Channel: c.updateChannel(), Signers: f.Signers, Plat: c.plat, BaseURL: f.ReleaseBase})
	if err != nil {
		log.Warn("core: updater-unavailable", "err", err.Error())
		c.upd = nil
	}

	// 4. procs.
	c.pr, err = procs.New(log, c.clean)
	if err != nil {
		log.Error("core: procs", "err", err.Error())
		c.pr = nil
	}
	if c.pr != nil {
		runAs := ""
		if c.cfg != nil {
			if u, e := c.plat.RunAsUser(c.cfg.Control); e == nil {
				runAs = u
			} else {
				log.Warn("core: runas", "err", e.Error())
			}
		}
		c.sh = c.plat.NewShell(log, c.pr, runAs)
	}

	// 9. webui — всегда и первой: sing-box может стартовать минутами, страница должна отвечать сразу.
	c.ui, err = webui.New(c, log, f.DevAssets, c.prevUI())
	if err != nil {
		log.Error("core: webui", "err", err.Error())
	} else if err = c.ui.Start(ctx); err != nil {
		log.Error("core: webui-start", "err", err.Error())
	} else {
		_ = os.WriteFile(filepath.Join(c.p.State, UIURLFile), []byte(c.ui.URL()+"\n"), 0600)
		c.savePrevUI()
		log.Info("core: webui", "port", c.ui.Status()["port"])
		c.emit(map[string]any{"t": "ui", "url": c.ui.URL()})
		c.publishStatus()
		c.publishStartInfo()
	}

	// 5–8. Сеть стартует в своей горутине: страница, health и alive не ждут загрузку/запуск sing-box.
	if c.cfg != nil && c.pr != nil {
		c.netDone = make(chan struct{})
		go func() {
			defer close(c.netDone)
			c.startNetwork(ctx)
			if isNil(c.getCh()) && !c.failed.Load() {
				c.sendGood() // канала нет (--no-channel / сбой, не требующий отката)
			}
			c.publishStatus()
		}()
	}

	// 10. Обновления: первая проверка и далее по расписанию; под одним мьютексом с остальными записями.
	if c.upd != nil && (c.cfg == nil || c.cfg.Update.Auto) {
		time.AfterFunc(updateFirst, func() { c.autoUpdate(ctx) })
	}
}

func (c *core) updateChannel() string {
	if c.cfg != nil && c.cfg.Update.Channel != "" {
		return c.cfg.Update.Channel
	}
	return "v3-latest"
}

// startNetwork — шаги 5–8: sing-box, агент, канал, forward. Поля компонентов ставятся под compMu.
func (c *core) startNetwork(ctx context.Context) {
	f, log := c.f, c.log
	var err error

	// 5. sing-box (не при --no-singbox и не при --no-channel).
	if !f.Mode.NoSingbox && !f.Mode.NoChannel {
		sb, e := singbox.New(c.cfg, c.p, log, c.clean, c.pr, singbox.Options{
			Mode: f.Mode, Instance: c.clean.Instance(),
			LANSocks: func() string {
				if fw := c.getFw(); fw != nil {
					return fw.InternalSocks()
				}
				return ""
			},
		})
		if e != nil {
			log.Error("core: singbox", "err", e.Error())
			c.failStart(e)
		} else {
			c.compMu.Lock()
			c.sb = sb
			c.compMu.Unlock()
			c.publishSingbox() // starting
			if e = sb.Start(ctx); e != nil {
				log.Error("core: singbox-start", "err", e.Error())
				c.failStart(e)
			}
			c.publishSingbox()
		}
	}

	// 6. Агент создаётся первым, но ещё не слушает (§5.1).
	if c.sh != nil {
		ag, e := agent.New(api.AgentDeps{
			Log: log.With("agent"), Shell: c.sh,
			Fwd: c.getFw,
			Act: c, Paths: c.p, Control: c.control.Load, Status: c.Status,
			MaxBody: 8 << 20, MaxDev: 100 << 20,
		})
		if e != nil {
			log.Error("core: agent", "err", e.Error())
		} else {
			c.compMu.Lock()
			c.ag = ag
			c.compMu.Unlock()
		}
	}

	// 7. Канал.
	if !f.Mode.NoChannel && c.ag != nil {
		ch, e := channel.New(c.cfg, c.getSb(), c.ag, log, c.clean, channel.Options{
			PC: c.pcName(), Version: f.Version, Rollback: f.RollbackReason, Mode: f.Mode,
		})
		if e != nil {
			log.Error("core: channel", "err", e.Error())
			c.failStart(e)
		} else {
			c.compMu.Lock()
			c.ch = ch
			c.compMu.Unlock()
			updates, unsub := ch.Subscribe()
			go c.watchChannel(ctx, updates, unsub)
			if err = ch.Start(ctx); err != nil {
				log.Error("core: channel-start", "err", err.Error())
				c.failStart(err)
			}
		}
	}

	// 8. forward (поверх канала).
	if ch := c.getCh(); ch != nil {
		fw, e := forward.New(c.cfg, ch, c.p, log, c.clean, f.Mode)
		if e != nil {
			log.Error("core: forward", "err", e.Error())
		} else {
			c.compMu.Lock()
			c.fw = fw
			c.compMu.Unlock()
			if e = fw.Start(ctx); e != nil {
				log.Error("core: forward-start", "err", e.Error())
			}
		}
	}
	// VPN/LAN-сторожа (vpnguard/languard) — N1b/N2; при Mode.AllowsTun() они будут подключены здесь.
}

func (c *core) getCh() api.Channel {
	c.compMu.RLock()
	defer c.compMu.RUnlock()
	return c.ch
}

func (c *core) getSb() api.Singbox {
	c.compMu.RLock()
	defer c.compMu.RUnlock()
	return c.sb
}

func (c *core) getFw() api.Forwarder {
	c.compMu.RLock()
	defer c.compMu.RUnlock()
	return c.fw
}

// devPCSuffix — на время разработки, параллельно с v2: имя ПК v3 на сервере отличается от имени v2,
// иначе channel при подключении убьёт сессию работающей Лаборатории v2 (pkill ra-lab session --pc <имя>).
// Убрать при выпуске v3 вместо v2.
const devPCSuffix = "-v3"

// pcName — имя ПК для сервера: явный --pc, иначе cfg.Name в латиницу (транслит, пробел → "-",
// лишнее выкинуть) + devPCSuffix. Пусто, если из имени ничего не осталось.
func (c *core) pcName() string {
	if c.f.PC != "" {
		return c.f.PC
	}
	if c.cfg == nil {
		return ""
	}
	return pcNameFor(c.cfg.Name)
}

// pcNameFor — имя на сервере из имени в конфиге; пусто, если из имени ничего не осталось.
func pcNameFor(cfgName string) string {
	n := strings.Trim(translitPC(cfgName), "-._")
	if len(n) > 40 {
		n = strings.Trim(n[:40], "-._")
	}
	if n == "" {
		return ""
	}
	return n + devPCSuffix
}

var translitMap = map[rune]string{
	'а': "a", 'б': "b", 'в': "v", 'г': "g", 'д': "d", 'е': "e", 'ё': "e", 'ж': "zh", 'з': "z", 'и': "i", 'й': "y",
	'к': "k", 'л': "l", 'м': "m", 'н': "n", 'о': "o", 'п': "p", 'р': "r", 'с': "s", 'т': "t", 'у': "u", 'ф': "f",
	'х': "kh", 'ц': "ts", 'ч': "ch", 'ш': "sh", 'щ': "shch", 'ъ': "", 'ы': "y", 'ь': "", 'э': "e", 'ю': "yu", 'я': "ya",
}

func translitPC(name string) string {
	var b strings.Builder
	for _, r := range strings.TrimSpace(name) {
		lower := unicode.ToLower(r)
		if t, ok := translitMap[lower]; ok {
			if lower != r && t != "" {
				t = strings.ToUpper(t[:1]) + t[1:]
			}
			b.WriteString(t)
			continue
		}
		switch {
		case r == ' ' || r == '\t':
			b.WriteByte('-')
		case r < 128 && (r == '.' || r == '_' || r == '-' || r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z'):
			b.WriteRune(r)
		}
	}
	return b.String()
}

// watchChannel: первый `up` → good (один раз) и Commit конфига.
func (c *core) watchChannel(ctx context.Context, ch <-chan api.ChannelState, unsub func()) {
	defer unsub()
	for {
		select {
		case <-ctx.Done():
			return
		case st, ok := <-ch:
			if !ok {
				return
			}
			c.log.Info("core: channel", "state", st.State, "path", st.Path, "reason", st.Reason, "session", st.Session)
			if st.State == "down" && fatalChannelReason(st.Reason) {
				c.failStart(errors.New(st.Reason))
			}
			if st.State != "up" {
				continue
			}
			c.upOnce.Store(true)
			c.clearLastErr()
			if c.gen != "" {
				if err := config.Commit(c.p, c.gen, c.start); err != nil {
					c.log.Warn("core: config-commit", "gen", c.gen, "err", err.Error())
				}
			}
			c.sendGood()
		}
	}
}

// bounded выполняет шаг остановки не дольше d: зависший компонент не должен держать выход ядра.
func (c *core) bounded(name string, d time.Duration, fn func()) {
	done := make(chan struct{})
	go func() { defer close(done); fn() }()
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-done:
	case <-t.C:
		c.log.Warn("core: stop-timeout", "component", name, "after", d.String())
	}
}

// stopComponents — обратный порядок, затем cleanup.Run("exit"). Каждый шаг ограничен по времени.
func (c *core) stopComponents() {
	stopCtx := func() (context.Context, context.CancelFunc) {
		return context.WithTimeout(context.Background(), stopStepTimeout)
	}
	if c.netDone != nil { // запуск сети уже отменён контекстом; ждём его конец, но не бесконечно
		select {
		case <-c.netDone:
		case <-time.After(stopStepTimeout):
			c.log.Warn("core: stop-timeout", "component", "network-start")
		}
	}
	for _, fn := range c.onStop {
		fn()
	}
	if c.ui != nil {
		ctx, cancel := stopCtx()
		_ = c.ui.Stop(ctx)
		cancel()
		_ = os.Remove(filepath.Join(c.p.State, UIURLFile))
	}
	for _, comp := range []api.Component{c.getFw(), c.getCh()} {
		if isNil(comp) {
			continue
		}
		ctx, cancel := stopCtx()
		if err := comp.Stop(ctx); err != nil {
			c.log.Warn("core: stop", "component", comp.Name(), "err", err.Error())
		}
		cancel()
	}
	if c.ag != nil {
		c.bounded("agent", stopStepTimeout, func() {
			if err := c.ag.Close(); err != nil {
				c.log.Warn("core: stop", "component", "agent", "err", err.Error())
			}
		})
	}
	if c.sh != nil {
		c.bounded("shell", stopStepTimeout, func() { _ = c.sh.KillAll() })
	}
	if sb := c.getSb(); !isNil(sb) {
		ctx, cancel := stopCtx()
		if err := sb.Stop(ctx); err != nil {
			c.log.Warn("core: stop", "component", "singbox", "err", err.Error())
		}
		cancel()
	}
	if c.pr != nil {
		ctx, cancel := stopCtx()
		_ = c.pr.KillAll(ctx)
		cancel()
	}
	c.bounded("cleanup", 30*time.Second, func() {
		for _, issue := range c.clean.Run(context.Background(), "exit") {
			c.log.Warn("core: cleanup-exit", "issue", issue)
		}
	})
}

func isNil[T comparable](v T) bool {
	var z T
	return v == z
}

func (c *core) aliveLoop(ctx context.Context) {
	t := time.NewTicker(aliveEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			c.emit(map[string]any{"t": api.MsgAlive})
		}
	}
}

func (c *core) healthLoop(ctx context.Context) {
	t := time.NewTicker(healthEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			var ms runtime.MemStats
			runtime.ReadMemStats(&ms)
			c.log.Info("health", "goroutines", runtime.NumGoroutine(), "heapMB", ms.HeapInuse>>20, "sysMB", ms.Sys>>20,
				"fds", openFDs(), "logDrops", c.log.Drops())
		}
	}
}

func (c *core) autoUpdate(ctx context.Context) {
	if ctx.Err() != nil {
		return
	}
	if err := c.UpdateNow(ctx); err != nil && err != api.ErrBusy {
		c.log.Warn("core: auto-update", "err", err.Error())
	}
	time.AfterFunc(updateEvery, func() { c.autoUpdate(ctx) })
}

// build — номер сборки из версии "3.0.<build>"; "dev" и прочее → 0 (любой выпуск новее).
func (c *core) build() int {
	v := c.f.Version
	n, _ := strconv.Atoi(v[strings.LastIndex(v, ".")+1:])
	return n
}
