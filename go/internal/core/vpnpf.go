package core

import (
	"context"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/platform"
	"remoteagents/internal/singbox"
)

// Этап 4: галочка «выход только через наш адрес» на macOS — pf-якорь (platform.PFKillSwitch). Якорь стоит, пока галочка и VPN
// включены (и при падении sing-box — это и есть блок); снимается выключением VPN/галочки, выходом, сторожем при смерти ядра
// (supervise.runCleanup) и при старте программы. Выключение снимает якорь первым делом, не дожидаясь sing-box.

// pfSwitch — управление якорем (в тестах подменяется).
type pfSwitch interface {
	Apply(ctx context.Context, tun string, servers []string) error
	Release(ctx context.Context) error
}

// tunPrefix — адрес нашего TUN (render_vpn.go): по нему находим utunN, который выдала ОС.
const tunPrefix = "172.19.8.1/"

type pfHolder struct {
	once sync.Once
	sw   pfSwitch
	ips  []string // последние известные адреса серверов (DNS под блоком недоступен)
}

func (g *tunGuard) pfSw() pfSwitch {
	g.pfh.once.Do(func() {
		if g.pfh.sw == nil && platform.PFSupported() && g.c.p.State != "" {
			g.pfh.sw = platform.NewPFKillSwitch(g.c.p.State)
		}
	})
	return g.pfh.sw
}

// releasePF — снять якорь (идемпотентно, без mu: выключение не ждёт зависшую операцию).
func (g *tunGuard) releasePF(ctx context.Context, why string) {
	sw := g.pfSw()
	if sw == nil {
		return
	}
	rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	defer cancel()
	if err := sw.Release(rctx); err != nil {
		g.c.log.Error("vpn.pf-release-failed", "why", why, "err", err.Error())
		return
	}
	g.c.log.Info("vpn.pf-released", "why", why)
}

// syncPF — привести якорь к желаемому: есть галочка и VPN нужен → поставить/перезагрузить (когда TUN поднят), иначе снять. Под mu.
func (g *tunGuard) syncPF(ctx context.Context, wantVPN, gotVPN bool) {
	sw := g.pfSw()
	if sw == nil {
		return
	}
	if !(g.lock() && wantVPN) {
		g.pfWhy = ""
		g.releasePF(ctx, "lock-or-vpn-off")
		return
	}
	if !gotVPN {
		return // процесс VPN не поднят: уже стоящий якорь остаётся (блок), новый до TUN не ставим
	}
	ifs, _ := g.c.plat.Interfaces()
	tun := platform.TunIfaceByAddr(ifs, tunPrefix)
	if tun == "" && hasIface(ifs, g.adapter("vpn")) {
		tun = g.adapter("vpn")
	}
	if tun == "" {
		g.pfWhy = "не найден интерфейс нашего TUN"
		g.c.log.Error("vpn.pf-no-tun")
		return
	}
	ips := singbox.VPNServerIPs(g.c.cfg)
	if len(ips) == 0 {
		ips = g.pfh.ips
	} else {
		g.pfh.ips = ips
	}
	actx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := sw.Apply(actx, tun, ips); err != nil {
		g.pfWhy = strings.TrimSpace(err.Error())
		g.c.log.Error("vpn.pf-failed", "err", g.pfWhy)
		return
	}
	g.pfWhy = ""
	g.c.log.Info("vpn.pf-applied", "tun", tun, "servers", len(ips))
}
