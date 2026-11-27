package core

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/singbox"
)

// tunGuard — сторож VPN (N1b) и ЛВС (N2) в общем sing-box. Только события: старт сети, смена сети, падение sing-box с TUN,
// команда /vpn, итог apply. Fail-open VPN: 1-я неудача — один повтор, 2-я — перезапуск без TUN (канал важнее), 3-я — off.
// ЛВС: упала с TUN — выключается до смены сети/настроек. Всё, что поднято, снимается выходом/падением ядра (cleanup по трейсам).
type tunGuard struct {
	c  *core
	mu sync.Mutex // одна операция за раз

	mode        string // текущий режим VPN (конфиг или /vpn)
	fails       int
	vpnState    string // off | up | failopen | foreign | error
	vpnWhy      string
	lanState    string // off | up | skipped-v2 | no-subnets | error
	lanWhy      string
	lastForeign string // последний чужой VPN, о котором писали в журнал
	lanOff      bool   // ЛВС выключена после падения до смены сети
	retry       *time.Timer
	snap        atomic.Value // map[string]any, последний снимок для Status
}

// status читает снимок без mu: Status() вызывается из event() под mu.
func (g *tunGuard) status() map[string]any {
	if v, ok := g.snap.Load().(map[string]any); ok {
		return v
	}
	return map[string]any{"mode": "off", "state": "off", "fails": 0, "lan": map[string]any{"state": "off"}}
}

func (g *tunGuard) event(name string, kv ...any) {
	g.c.log.Info(name, kv...)
	st := g.statusLocked()
	g.snap.Store(st)
	g.c.publish("vpn", st)
	g.c.publishStatus()
}

// statusLocked — status без повторного захвата mu (вызывается под mu).
func (g *tunGuard) statusLocked() map[string]any {
	return map[string]any{"mode": g.mode, "state": g.vpnState, "reason": g.vpnWhy, "fails": g.fails,
		"lan": map[string]any{"state": g.lanState, "reason": g.lanWhy}}
}

func hasIface(ifs []api.Iface, name string) bool {
	for _, f := range ifs {
		if strings.EqualFold(f.Name, name) {
			return true
		}
	}
	return false
}

// reconcile приводит sing-box к желаемому состоянию; reason — событие-причина (в журнал).
func (g *tunGuard) reconcile(ctx context.Context, reason string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	c := g.c
	sb := c.getSb()
	if isNil(sb) || c.cfg == nil || !c.f.Mode.AllowsTun() {
		return
	}
	ifs, _ := c.plat.Interfaces()
	var want api.Effective

	// VPN
	switch {
	case g.mode == "off":
		g.vpnState, g.vpnWhy = "off", ""
	case g.fails >= 3:
		g.vpnState, g.vpnWhy = "off", "три неудачные проверки — выключен до команды /vpn"
	case g.vpnState == "failopen" && reason != "net-changed" && reason != "foreign-changed" && reason != "vpn-cmd":
		// остаёмся без TUN до смены сети или команды
	default:
		if fv := c.plat.ForeignVPN(); fv != "" {
			g.vpnState, g.vpnWhy = "foreign", "работает другой VPN ("+fv+")"
			if g.mode == "only" {
				g.vpnWhy += " — отключите его, чтобы работал наш"
			}
			if fv != g.lastForeign {
				g.event("vpn.skipped-foreign", "iface", fv, "mode", g.mode)
			}
			g.lastForeign = fv
		} else {
			g.lastForeign = ""
			want.VPN = true
		}
	}

	// ЛВС
	if len(c.cfg.LAN) > 0 {
		nets, _ := singbox.LANSubnets(c.cfg)
		switch {
		case g.lanOff && reason != "net-changed" && reason != "vpn-cmd":
			want.LAN = false
		case hasIface(ifs, "RA2-LAN"):
			g.lanState, g.lanWhy = "skipped-v2", "ЛВС уже держит Лаборатория v2 (RA2-LAN)"
			g.event("lan.skipped-v2")
		case len(nets) == 0:
			g.lanState, g.lanWhy = "no-subnets", "в конфиге нет подсетей клиники"
			g.event("lan.no-subnets")
		case c.getFw() == nil || c.getFw().InternalSocks() == "":
			g.lanState, g.lanWhy = "off", "нет внутреннего SOCKS"
		default:
			want.LAN = true
			g.lanOff = false
		}
	}

	if want == sb.Effective() {
		g.finish(want)
		return
	}
	actx, cancel := context.WithTimeout(ctx, 40*time.Second)
	err := sb.Apply(actx, want)
	cancel()
	if err != nil {
		c.log.Error("vpn.apply-failed", "reason", reason, "err", err.Error())
		g.lanOff = g.lanOff || want.LAN
		g.lanState, g.lanWhy = "error", sanitize(err.Error())
		if want.VPN {
			g.failLocked(ctx, "apply: "+sanitize(err.Error()))
		}
		return
	}
	g.finish(want)
	if want.VPN {
		go g.probe(ctx)
	}
}

// finish — статусы по факту применённого состояния.
func (g *tunGuard) finish(got api.Effective) {
	if got.VPN {
		g.vpnState, g.vpnWhy = "up", ""
	}
	if got.LAN {
		g.lanState, g.lanWhy = "up", ""
	} else if g.lanState == "up" {
		g.lanState = "off"
	}
	g.event("vpn.state", "vpn", g.vpnState, "lan", g.lanState)
}

// probe — одна проверка туннеля (после включения): запрос к адресу не из РФ идёт через TUN → vpn-out.
func (g *tunGuard) probe(ctx context.Context) {
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(cctx, http.MethodGet, singbox.VPNProbeURL, nil)
	resp, err := http.DefaultClient.Do(req)
	ok := err == nil && resp.StatusCode == http.StatusNoContent
	if resp != nil {
		resp.Body.Close()
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if ok {
		g.fails = 0
		g.event("vpn.probe-ok")
		return
	}
	why := "проверка туннеля не прошла"
	if err != nil {
		why += ": " + sanitize(err.Error())
	}
	g.failLocked(ctx, why)
}

// failLocked — шаг лестницы fail-open. Под mu.
func (g *tunGuard) failLocked(ctx context.Context, why string) {
	g.fails++
	g.vpnWhy = why
	switch {
	case g.fails == 1:
		g.vpnState = "error"
		g.event("vpn.fail", "n", 1, "why", why)
		if g.retry != nil {
			g.retry.Stop()
		}
		// один повтор проверки — разовый таймер после события неудачи, не опрос
		g.retry = time.AfterFunc(5*time.Second, func() { go g.probe(ctx) })
	case g.fails == 2:
		g.vpnState = "failopen"
		g.event("vpn.failopen", "why", why)
		g.dropVPN(ctx)
	default:
		g.vpnState, g.mode = "off", "off"
		g.event("vpn.off", "why", why)
		g.dropVPN(ctx)
	}
}

// dropVPN — перезапуск sing-box без TUN VPN (ЛВС, если была, остаётся). Горутина: под mu Apply не вызываем повторно.
func (g *tunGuard) dropVPN(ctx context.Context) {
	sb := g.c.getSb()
	if isNil(sb) {
		return
	}
	e := sb.Effective()
	e.VPN = false
	go func() {
		actx, cancel := context.WithTimeout(ctx, 40*time.Second)
		defer cancel()
		if err := sb.Apply(actx, e); err != nil {
			g.c.log.Error("vpn.drop-failed", "err", err.Error())
		}
	}()
}

// onTunCrash — sing-box с TUN упал (само-откат без TUN уже сделан в singbox). Считается неудачей; ЛВС до смены сети выключена.
func (g *tunGuard) onTunCrash(ctx context.Context, e api.Effective) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.c.log.Error("tun.crashed", "vpn", e.VPN, "lan", e.LAN)
	if e.LAN {
		g.lanOff, g.lanState, g.lanWhy = true, "error", "sing-box с TUN упал; повтор при смене сети"
	}
	if e.VPN {
		g.fails++
		g.vpnWhy = "sing-box с TUN упал"
		switch {
		case g.fails >= 3:
			g.vpnState, g.mode = "off", "off"
			g.event("vpn.off", "why", g.vpnWhy)
		default:
			g.vpnState = "failopen"
			g.event("vpn.failopen", "why", g.vpnWhy)
		}
		return
	}
	g.event("lan.crashed")
}

// setMode — команда /vpn (в конфиг не пишется): сброс счётчика и пересчёт.
func (g *tunGuard) setMode(ctx context.Context, mode string) {
	g.mu.Lock()
	g.mode, g.fails, g.vpnState, g.vpnWhy = mode, 0, "off", ""
	g.mu.Unlock()
	g.reconcile(ctx, "vpn-cmd")
}

func (c *core) startTunGuard(ctx context.Context) {
	if c.cfg == nil || !c.f.Mode.AllowsTun() {
		return
	}
	g := c.tun
	if g == nil || isNil(c.getSb()) {
		return
	}
	go g.reconcile(ctx, "start") // по конфигу; по умолчанию (vpn off, lan пуст) ничего не включается
}
