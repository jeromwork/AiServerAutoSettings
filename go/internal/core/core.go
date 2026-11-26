// Package core — сборка ядра: порядок старта (§10 плана), обратная остановка, api.Actions.
package core

import (
	"context"
	"encoding/json"
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
	opMu    sync.Mutex // UpdateNow, ConfigApply и прочие записи — одна за раз (+ LockOp между процессами)

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
	if c.ch == nil {
		// Нет канала (нет конфига / --no-channel / сбой): ждать «up» нечего, версия жива, когда страница поднята.
		c.sendGood()
	}
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

	if c.cfg != nil && c.pr != nil {
		c.startNetwork(ctx)
	}

	// 9. webui — всегда.
	c.ui, err = webui.New(c, log, f.DevAssets)
	if err != nil {
		log.Error("core: webui", "err", err.Error())
	} else if err = c.ui.Start(ctx); err != nil {
		log.Error("core: webui-start", "err", err.Error())
	} else {
		_ = os.WriteFile(filepath.Join(c.p.State, UIURLFile), []byte(c.ui.URL()+"\n"), 0600)
		log.Info("core: webui", "port", c.ui.Status()["port"])
		c.emit(map[string]any{"t": "ui", "url": c.ui.URL()})
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

// startNetwork — шаги 5–8: sing-box, агент, канал, forward.
func (c *core) startNetwork(ctx context.Context) {
	f, log := c.f, c.log
	var err error

	// 5. sing-box (не при --no-singbox и не при --no-channel).
	if !f.Mode.NoSingbox && !f.Mode.NoChannel {
		c.sb, err = singbox.New(c.cfg, c.p, log, c.clean, c.pr, singbox.Options{
			Mode: f.Mode, Instance: c.clean.Instance(),
			LANSocks: func() string {
				if fw := c.fw; fw != nil {
					return fw.InternalSocks()
				}
				return ""
			},
		})
		if err != nil {
			log.Error("core: singbox", "err", err.Error())
			c.sb = nil
		} else if err = c.sb.Start(ctx); err != nil {
			log.Error("core: singbox-start", "err", err.Error())
		}
	}

	// 6. Агент создаётся первым, но ещё не слушает (§5.1).
	if c.sh != nil {
		c.ag, err = agent.New(api.AgentDeps{
			Log: log.With("agent"), Shell: c.sh,
			Fwd: func() api.Forwarder { return c.fw },
			Act: c, Paths: c.p, Control: c.control.Load, Status: c.Status,
			MaxBody: 8 << 20, MaxDev: 100 << 20,
		})
		if err != nil {
			log.Error("core: agent", "err", err.Error())
			c.ag = nil
		}
	}

	// 7. Канал.
	if !f.Mode.NoChannel && c.ag != nil {
		c.ch, err = channel.New(c.cfg, c.sb, c.ag, log, c.clean, channel.Options{
			PC: c.pcName(), Version: f.Version, Rollback: f.RollbackReason, Mode: f.Mode,
		})
		if err != nil {
			log.Error("core: channel", "err", err.Error())
			c.ch = nil
		} else {
			updates, unsub := c.ch.Subscribe()
			go c.watchChannel(ctx, updates, unsub)
			if err = c.ch.Start(ctx); err != nil {
				log.Error("core: channel-start", "err", err.Error())
			}
		}
	}

	// 8. forward (поверх канала).
	if c.ch != nil {
		c.fw, err = forward.New(c.cfg, c.ch, c.p, log, c.clean, f.Mode)
		if err != nil {
			log.Error("core: forward", "err", err.Error())
			c.fw = nil
		} else if err = c.fw.Start(ctx); err != nil {
			log.Error("core: forward-start", "err", err.Error())
		}
	}
	// VPN/LAN-сторожа (vpnguard/languard) — N1b/N2; при Mode.AllowsTun() они будут подключены здесь.
}

func (c *core) pcName() string {
	if c.f.PC != "" {
		return c.f.PC
	}
	if c.cfg != nil {
		return c.cfg.Name
	}
	return ""
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
			if st.State != "up" {
				continue
			}
			if c.gen != "" {
				if err := config.Commit(c.p, c.gen, c.start); err != nil {
					c.log.Warn("core: config-commit", "gen", c.gen, "err", err.Error())
				}
			}
			c.sendGood()
		}
	}
}

// stopComponents — обратный порядок, затем cleanup.Run("exit").
func (c *core) stopComponents() {
	stopCtx := func() (context.Context, context.CancelFunc) {
		return context.WithTimeout(context.Background(), stopStepTimeout)
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
	for _, comp := range []api.Component{c.fw, c.ch} {
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
		if err := c.ag.Close(); err != nil {
			c.log.Warn("core: stop", "component", "agent", "err", err.Error())
		}
	}
	if c.sh != nil {
		_ = c.sh.KillAll()
	}
	if !isNil(c.sb) {
		ctx, cancel := stopCtx()
		if err := c.sb.Stop(ctx); err != nil {
			c.log.Warn("core: stop", "component", "singbox", "err", err.Error())
		}
		cancel()
	}
	if c.pr != nil {
		ctx, cancel := stopCtx()
		_ = c.pr.KillAll(ctx)
		cancel()
	}
	for _, issue := range c.clean.Run(context.Background(), "exit") {
		c.log.Warn("core: cleanup-exit", "issue", issue)
	}
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
