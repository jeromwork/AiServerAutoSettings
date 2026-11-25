// Package core assembles the v2 app.py components; only configured parts exist.
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
	"strings"
	"sync"
	"syscall"
	"time"

	"remoteagents/internal/agent"
	"remoteagents/internal/api"
	"remoteagents/internal/bus"
	"remoteagents/internal/channel"
	"remoteagents/internal/cleanup"
	"remoteagents/internal/config"
	"remoteagents/internal/deps"
	"remoteagents/internal/disk"
	"remoteagents/internal/forward"
	"remoteagents/internal/journal"
	"remoteagents/internal/platform"
	"remoteagents/internal/procs"
	"remoteagents/internal/singbox"
	"remoteagents/internal/update"
	"remoteagents/internal/vpnrun"
	"remoteagents/internal/webui"
)

type Flags struct {
	Home, Config, PasswordFile, PC, DevAssets, Pprof, RollbackReason, ReleaseBase string
	Launcher                                                                      string
	Version, ReleaseRepo                                                          string
	Signers                                                                       []string
	Mode                                                                          api.Mode
	ExitAfter                                                                     time.Duration
}

type App struct {
	f        Flags
	p        api.Paths
	cfg      *api.Config
	log      *journal.Journal
	bus      *bus.Bus
	pr       api.Procs
	updater  api.Updater
	cleaner  *cleanup.Cleaner
	link     *channel.Link
	rounds   *channel.Rounds
	sb       api.Singbox
	fwd      api.Forwarder
	disk     *disk.Disk
	vpn      *vpnrun.Runner
	ui       *webui.UI
	net      *platform.NetWatch
	agent    *agent.Agent
	parts    []api.Component
	stop     chan int
	once     sync.Once
	onceAuto sync.Once
	op       sync.Mutex
	vpnMu    sync.Mutex
	vpnCfg   *api.Config
	started  time.Time
}

func Run(ctx context.Context, f Flags) int {
	p := api.NewPaths(f.Home)
	log, err := journal.New(p, api.StreamCore)
	if err != nil {
		fmt.Fprintln(os.Stderr, "core: cannot open journal")
		return 1
	}
	defer log.Close()
	a := &App{f: f, p: p, log: log, bus: bus.New(log), stop: make(chan int, 1), started: time.Now()}
	defer a.bus.Close()
	a.pr = procs.New(log, a.bus)
	a.bus.SetTickHook(func() {
		if rssBytes() > 300<<20 {
			a.leave(api.ExitMemory)
		}
	})
	if f.Config != "" {
		a.cfg, err = config.LoadFile(f.Config, f.PasswordFile, log)
	} else {
		a.cfg, _, err = config.Load(p, log)
	}
	// An empty home is a protocol-only invocation: no listeners, services or cleanup.
	if errors.Is(err, config.ErrNoConfig) || (f.Config != "" && errors.Is(err, os.ErrNotExist)) {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"t": api.MsgNoConfig})
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"t": api.MsgExit})
		return 0
	}
	if err != nil {
		log.Error("settings.failed", "err", err)
		return 1
	}
	for _, dir := range []string{p.State, p.Tmp, p.Versions, filepath.Join(p.Home, "private")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			log.Error("mkdir", "err", err)
			return 1
		}
	}
	if _, err := os.Stat(filepath.Join(p.State, "control.json")); errors.Is(err, os.ErrNotExist) {
		if _, present := a.cfg.Sections["control"]; present {
			if err := agent.SetEnabled(p, a.cfg.Control.Enabled); err != nil {
				log.Warn("control.init", "err", err)
			}
		}
	}
	ctx, cancel := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if f.ExitAfter > 0 {
		var done context.CancelFunc
		ctx, done = context.WithTimeout(ctx, f.ExitAfter)
		defer done()
	}
	a.cleaner, err = cleanup.New(p, log)
	if err != nil {
		log.Error("cleanup.init", "err", err)
		return 1
	}
	bundle := &deps.Bundle{}
	if _, err = bundle.Prepare(p.Home, log); err != nil {
		log.Warn("bins", "err", err)
	}
	if f.Mode.AllowsSystemChanges() {
		a.cleaner.Run(ctx, "startup")
	}
	a.updater, err = update.New(p, log, update.Options{Repo: f.ReleaseRepo, Signers: f.Signers, Channel: a.cfg.Update.Channel, BaseURL: f.ReleaseBase})
	if err != nil {
		log.Error("update.init", "err", err)
		return 1
	}
	a.link = channel.New(channel.Options{Paths: p, Version: f.Version, ExeVersion: f.Version, Rollback: f.RollbackReason, Bus: a.bus, Log: log, Mask: journal.Mask, Snapshot: a.snapshot, Report: a.report,
		Update:      func(send func(map[string]any)) { go a.updateRequest(ctx, send, false) },
		RollbackEXE: func(send func(map[string]any)) { go a.updateRequest(ctx, send, true) }})
	uiExe := a.launcher()
	if !f.Mode.AllowsSystemChanges() {
		uiExe = ""
	}
	a.ui, err = webui.New(a, log, a.bus, uiExe)
	if err != nil {
		log.Warn("webui", "err", err)
	}
	// Reverse-order teardown also covers a partially completed startup.
	defer func() { cancel(); a.shutdown() }()
	hasChannel := !a.cfg.VPNOnly && a.cfg.Enabled("server") && a.cfg.Enabled("paths") && !f.Mode.NoChannel
	if hasChannel {
		a.agent, err = agent.New(api.AgentDeps{Log: log, Shell: platform.Current().NewShell(log, a.pr), Fwd: func() api.Forwarder { return a.fwd }, Act: a, Paths: p, Control: func() bool { return agent.Enabled(p) }, Status: a.Status, MaxDev: 100 << 20})
		if err != nil {
			log.Error("agent.init", "err", err)
			return 1
		}
		a.sb, err = singbox.New(a.cfg, p, log, nil, a.pr, singbox.Options{Mode: f.Mode, Bus: a.bus, Binary: bundle.Find(binaryName("sing-box"))})
		if err != nil {
			log.Error("singbox.init", "err", err)
			return 1
		}
		a.rounds = channel.NewRounds(a.cfg, a.sb, a.agent, p, log, a.pr, a.bus, channel.RoundOptions{PC: f.PC, Version: f.Version, Rollback: f.RollbackReason, SSH: bundle.Find("openssh/" + binaryName("ssh")), Mode: f.Mode})
		transport := newTransport(a)
		a.start(ctx, transport)
		a.start(ctx, a.rounds)
		if a.cfg.Enabled("forward") || a.cfg.Enabled("forwards") || a.cfg.Enabled("lan") || a.cfg.Enabled("lanProxy") || a.cfg.Enabled("happier") || a.cfg.Enabled("disk") {
			a.fwd, err = forward.New(a.cfg, transport, p, log, nil, f.Mode)
			if err != nil {
				log.Error("forward.init", "err", err)
				return 1
			}
			a.start(ctx, a.fwd)
		}
		if a.cfg.Enabled("disk") {
			a.disk = disk.New(disk.Options{Config: a.cfg, Installed: filepath.Dir(a.launcher()), Exe: bundle.Find(binaryName("syncthingtray")), ExplorerExe: bundle.Find("disk-explorer.exe"), Procs: a.pr, Channel: transport, Forward: a.fwd, Bus: a.bus, Log: log})
			a.start(ctx, a.disk)
		}
		a.start(ctx, a.sb)
	}
	if a.cfg.Enabled("vpn") && f.Mode.AllowsTun() {
		copyCfg := *a.cfg
		a.vpnCfg = &copyCfg
		a.loadVPNMode()
		a.vpn = vpnrun.New(p.Home, a.pr, log, a.bus, "", "")
		var v struct {
			ProbeURL      string `json:"probe_url"`
			CamelProbeURL string `json:"probeURL"`
		}
		_ = a.cfg.Section("vpn", &v)
		a.vpn.ProbeURL = v.ProbeURL
		if a.vpn.ProbeURL == "" {
			a.vpn.ProbeURL = v.CamelProbeURL
		}
		a.vpn.Reset()
		for _, topic := range []string{"settings.loaded", "net.changed", "vpn.request"} {
			a.bus.Subscribe(topic, func(bus.Event) { go a.applyVPN(ctx) })
		}
	}
	if hasChannel || a.vpn != nil {
		a.net = platform.NewNetWatch(a.bus, log)
		a.parts = append(a.parts, a.net) // app.start owns registration.
		a.bus.Subscribe("net.changed", func(bus.Event) { a.net.Ack() })
	}
	a.bus.Subscribe("app.stop", func(bus.Event) { a.leave(api.ExitOK) })
	a.bus.Subscribe("app.restart", func(bus.Event) { a.leave(api.ExitRestart) })
	if a.ui != nil {
		a.parts = append(a.parts, a.ui)
		if err := a.ui.Start(ctx); err != nil {
			log.Warn("webui.failed", "err", err)
		}
		a.link.Send(map[string]any{"t": "ui", "url": a.ui.URL()})
	}
	a.link.Send(map[string]any{"t": api.MsgConfigOK, "channel": hasChannel})
	a.bus.Publish("app.start", nil)
	a.bus.Publish("settings.loaded", map[string]any{"paths": a.cfg.Paths.Entries, "lans": a.cfg.LAN})
	if a.cfg.Update.Auto && a.cfg.Enabled("update") {
		a.bus.Subscribe("channel.up", func(bus.Event) { go a.autoUpdate(ctx) })
	}
	select {
	case code := <-a.stop:
		if code == api.ExitOK {
			a.link.Send(map[string]any{"t": api.MsgExit})
		}
		return code
	case <-ctx.Done():
		a.link.Send(map[string]any{"t": api.MsgExit})
		return 0
	}
}
func (a *App) launcher() string {
	if a.f.Launcher != "" {
		return a.f.Launcher
	}
	return executable()
}
func executable() string { s, _ := os.Executable(); return s }
func binaryName(s string) string {
	if runtime.GOOS == "windows" {
		return s + ".exe"
	}
	return s
}
func (a *App) start(ctx context.Context, c api.Component) {
	if err := c.Start(ctx); err != nil {
		a.log.Warn(c.Name()+".failed", "err", err)
		return
	}
	a.parts = append(a.parts, c)
}
func (a *App) leave(code int) { a.once.Do(func() { a.stop <- code }) }
func (a *App) shutdown() {
	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Second)
	defer cancel()
	// Stop UI and network notifications, then VPN, then the remaining components in reverse order.
	vpnStopped := false
	stopVPN := func() {
		if vpnStopped {
			return
		}
		vpnStopped = true
		a.vpnMu.Lock()
		defer a.vpnMu.Unlock()
		if a.vpn != nil {
			if err := a.vpn.Stop(); err != nil {
				a.log.Warn("vpn.stop", "err", err)
			}
			a.vpn.Close()
		}
	}
	for i := len(a.parts) - 1; i >= 0; i-- {
		part := a.parts[i]
		if part.Name() != "webui" && part.Name() != "netwatch" {
			stopVPN()
		}
		if err := part.Stop(ctx); err != nil {
			a.log.Warn("stop", "part", part.Name(), "err", err)
		}
	}
	stopVPN()
	if a.agent != nil {
		_ = a.agent.Close()
	}
	_ = a.pr.KillAll(ctx)
	if a.f.Mode.AllowsSystemChanges() {
		a.cleaner.Run(ctx, "exit")
	}
	_ = a.link.Stop(ctx)
}
func (a *App) Status() map[string]any {
	st := map[string]any{"home": a.p.Home, "version": a.f.Version, "rollback": a.f.RollbackReason, "computer": a.f.PC, "uptime_s": int(time.Since(a.started).Seconds()), "rss_mb": float64(rssBytes()) / 1048576, "events": a.bus.Count(), "config": a.configStatus(), "control": agent.Enabled(a.p)}
	for _, c := range a.parts {
		st[c.Name()] = c.Status()
	}
	if a.link != nil {
		st["link"] = a.link.Status()
	}
	if a.rounds != nil {
		st["uplink"] = a.rounds.Uplink.Status()
	}
	a.vpnMu.Lock()
	if a.vpn != nil {
		st["vpn"] = map[string]any{"mode": a.vpnCfg.VPN.Mode, "running": a.vpn.Running()}
	}
	a.vpnMu.Unlock()
	return st
}
func (a *App) configStatus() map[string]any {
	c := config.Status(a.p)
	if !c.Has && a.f.Config != "" {
		c.Has = true
		c.Name = a.cfg.Name
		if len(a.cfg.Servers) > 0 {
			c.Server = a.cfg.Servers[0].Host
		}
	}
	return map[string]any{"has": c.Has, "name": c.Name, "server": c.Server, "time": c.Time}
}

func (a *App) snapshot() channel.Snapshot {
	s := channel.Snapshot{}
	if a.rounds != nil {
		r := a.rounds.Status()
		s.Round, _ = r["round"].(int)
		if c, ok := r["channel"].(map[string]any); ok && c != nil {
			s.Channel = &channel.Route{Path: fmt.Sprint(c["path"]), RPort: intValue(c["rport"])}
		}
		if rows, ok := r["ranking"].([]map[string]any); ok {
			for _, row := range rows {
				s.Ranking = append(s.Ranking, channel.Ranking{Path: fmt.Sprint(row["path"]), Outcome: fmt.Sprint(row["outcome"]), Reason: fmt.Sprint(row["reason"])})
			}
		}
		s.Uplink = a.rounds.Uplink.Current()
		s.UplinkOver = fmt.Sprint(a.rounds.Uplink.Status()["over"])
	}
	if a.cfg != nil {
		s.VPNMode = a.cfg.VPN.Mode
		if h := a.cfg.Happier.LocalWeb; h != nil && h.Enabled {
			s.HappierPort = h.Port
		}
	}
	if a.disk != nil {
		st := a.disk.Status()
		s.DiskRunning = st["state"] == "running"
		s.DiskHome, _ = st["base"].(string)
	}
	a.vpnMu.Lock()
	if a.vpn != nil {
		s.VPNMode = a.vpnCfg.VPN.Mode
		if a.vpn.Running() {
			s.VPNState = "работает"
		} else {
			s.VPNState = "остановлен"
		}
	}
	a.vpnMu.Unlock()
	return s
}
func (a *App) report() string {
	st := a.Status()
	b, _ := json.MarshalIndent(st, "", "  ")
	return journal.Mask(string(b) + "\nПоследние 200 записей журнала:\n" + strings.Join(a.log.Tail(200), "\n"))
}
func intValue(v any) int {
	switch n := v.(type) {
	case int:
		return n
	case float64:
		return int(n)
	}
	return 0
}

var _ api.Actions = (*App)(nil)
