package core

import (
	"context"
	"strings"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/platform"
	"remoteagents/internal/singbox"
)

// Этап 1b: защита от более мелких маршрутов чужого VPN. Наши маршруты 0/1+128/1 проигрывают чужим /2…/8 и мельче:
// проверяем, что 14 адресов (по одному из каждой /4, кроме 224/4 и 240/4 — они не публичные) выходят через наш TUN;
// если нет — читаем таблицу маршрутов, нарезаем route_address блоками /min(L+1, MaxVPNSplit) и перезапускаем VPN один раз.
// Только события: проверка идёт после включения и на net-changed/foreign-changed (через probe), таймеров нет.

// probeAddrs — по одному публичному адресу из каждой /4 (вне vpnExclude).
var probeAddrs = []string{
	"8.8.8.8:53", "20.20.20.20:53", "34.34.34.34:53", "52.52.52.52:53", "74.125.0.1:53", "88.88.88.88:53",
	"104.16.0.1:53", "120.120.120.120:53", "130.130.130.130:53", "151.101.1.1:53", "170.170.170.170:53",
	"185.185.185.185:53", "199.199.199.199:53", "208.67.222.222:53",
}

// foreignRoutes — чтение таблицы маршрутов (подменяется в тестах): длина самого длинного чужого публичного префикса и адаптер.
var foreignRoutes = platform.ForeignRoutePrefix

// sweep — сколько проб ушло мимо нашего TUN и через какой адаптер (первый встреченный).
func (g *tunGuard) sweep() (bad int, via string) {
	ours := g.adapter("vpn")
	for _, a := range probeAddrs {
		out := g.c.plat.ExitIface(a)
		if out != "" && strings.EqualFold(out, ours) {
			continue
		}
		bad++
		if via == "" {
			via = out
		}
	}
	return bad, via
}

// checkRoutes — этап 1b: проверка проб, при необходимости нарезка и одно перезапуск VPN. Возвращает число плохих проб после
// всех мер и адаптер, куда они ушли; handled — состояние уже изменено (отказ перезапуска), probe дальше не идёт.
func (g *tunGuard) checkRoutes(ctx context.Context) (bad int, via string, handled bool) {
	bad, via = g.sweep()
	if bad == 0 {
		g.setBypass("")
		return 0, "", false
	}
	l, fvia := foreignRoutes()
	want := min(l+1, singbox.MaxVPNSplit)
	if l == 0 || int(g.split.Load()) >= want {
		return bad, g.pickVia(via, fvia, bad), false
	}
	g.mu.Lock()
	if g.vpnState == "foreign" || g.vpnState == "off" || g.mode == "off" {
		g.mu.Unlock()
		return bad, via, true
	}
	g.split.Store(int32(want))
	g.c.log.Info("vpn.split", "len", want, "foreign", fvia, "bad", bad)
	if err := g.restartVPN(ctx); err != nil {
		g.failLocked(ctx, "apply: "+sanitize(err.Error()))
		g.mu.Unlock()
		return bad, via, true
	}
	g.event("vpn.state", "vpn", g.vpnState, "split", want)
	g.mu.Unlock()
	bad, via = g.sweep()
	return bad, g.pickVia(via, fvia, bad), false
}

func (g *tunGuard) pickVia(via, fvia string, bad int) string {
	if bad == 0 {
		return ""
	}
	if via == "" {
		via = fvia
	}
	if via == "" {
		via = "не определён"
	}
	return via
}

// restartVPN — перерисовать конфиг VPN и перезапустить процесс (те же Effective). Под mu.
func (g *tunGuard) restartVPN(ctx context.Context) error {
	vsb := g.c.getVpnSb()
	if isNil(vsb) {
		return nil
	}
	defer g.c.underlay()
	actx, cancel := context.WithTimeout(ctx, 40*time.Second)
	defer cancel()
	return vsb.Apply(actx, api.Effective{VPN: true})
}

// resetSplit — чужих маршрутов нет, нарезка не нужна: вернуть 0/1 (перезапуск — отдельно, если VPN уже поднят). Под mu.
func (g *tunGuard) resetSplit(ctx context.Context) {
	if g.split.Load() == 0 {
		return
	}
	g.split.Store(0)
	g.bypass = ""
	vsb := g.c.getVpnSb()
	if !isNil(vsb) && vsb.Effective().VPN {
		g.c.log.Info("vpn.split", "len", 0)
		if err := g.restartVPN(ctx); err != nil {
			g.c.log.Error("vpn.split-reset-failed", "err", err.Error())
		}
	}
}

func (g *tunGuard) setBypass(via string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.bypass == via {
		return
	}
	g.bypass = via
	g.event("vpn.bypass", "via", via)
}
