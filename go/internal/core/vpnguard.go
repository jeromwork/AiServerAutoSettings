package core

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/platform"
	"remoteagents/internal/singbox"
)

// tunGuard — сторож VPN (N1b, отдельный процесс sing-box) и ЛВС (N2, общий sing-box с каналом). Только события: старт сети, смена сети, падение sing-box с TUN,
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
	lastForeign string       // последний чужой VPN, о котором писали в журнал
	underlay    string       // адаптер, через который реально идёт трафик к нашему серверу (поверх чего работает VPN)
	split       atomic.Int32 // длина нарезки route_address VPN (этап 1b), 0 — стандартные 0/1
	bypass      string       // адаптер, куда уходят пробы мимо нашего TUN после нарезки ("" — нет)
	lanOff      bool         // ЛВС выключена после падения до смены сети
	retry       *time.Timer
	exitBusy    atomic.Bool  // проверка выхода уже идёт
	exit        atomic.Value // exitResult, последний итог проверки выхода
	inst        string       // тесты: экземпляр вместо c.clean.Instance()
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
	st := map[string]any{"mode": g.mode, "state": g.vpnState, "reason": g.vpnWhy, "fails": g.fails,
		"lan": map[string]any{"state": g.lanState, "reason": g.lanWhy}}
	if g.underlay != "" {
		st["underlay"] = g.underlay
	}
	if n := g.split.Load(); n > 0 {
		st["split"] = "/" + strconv.Itoa(int(n))
	}
	if g.bypass != "" {
		st["bypass"] = g.bypass
	}
	if r, ok := g.exit.Load().(exitResult); ok {
		st["exit"] = r
	}
	return st
}

func (g *tunGuard) adapter(part string) string {
	inst := g.inst
	if inst == "" && g.c.clean != nil {
		inst = g.c.clean.Instance()
	}
	return singbox.AdapterName(inst, part)
}

func hasIface(ifs []api.Iface, name string) bool {
	for _, f := range ifs {
		if strings.EqualFold(f.Name, name) {
			return true
		}
	}
	return false
}

// vpnUnderlay — «нижний» адаптер VPN сейчас: куда ОС ведёт трафик к серверу (чужой VPN или физический адаптер).
// Адрес сервера запоминается: DNS недоступен — берём прошлый. Узлов нет — прежнее поведение (PhysicalInterface).
func (c *core) vpnUnderlay() string {
	addr := singbox.VPNServerAddr(c.cfg)
	c.underMu.Lock()
	if addr == "" {
		addr = c.underAddr
	} else {
		c.underAddr = addr
	}
	c.underMu.Unlock()
	return platform.UnderlayInterface(addr)
}

// reconcile приводит процессы sing-box к желаемому состоянию; reason — событие-причина (в журнал).
// VPN — отдельный процесс (vsb): включение/выключение/падение не трогает sing-box канала и ЛВС (sb).
func (g *tunGuard) reconcile(ctx context.Context, reason string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	c := g.c
	sb, vsb := c.getSb(), c.getVpnSb()
	if (isNil(sb) && isNil(vsb)) || c.cfg == nil || !c.f.Mode.AllowsTun() {
		return
	}
	ifs, _ := c.plat.Interfaces()
	wantVPN := false

	// VPN
	switch {
	case isNil(vsb):
		g.vpnState, g.vpnWhy = "off", ""
	case g.mode == "off":
		g.vpnState, g.vpnWhy = "off", ""
		if g.retry != nil {
			g.retry.Stop() // отложенная проверка не должна вмешиваться после выключения
		}
	case g.fails >= 3:
		g.vpnState, g.vpnWhy = "off", "три неудачные проверки — выключен до команды /vpn"
	case g.vpnState == "failopen" && reason != "net-changed" && reason != "foreign-changed" && reason != "vpn-cmd":
		// остаёмся без TUN до смены сети или команды
	default:
		// чужой VPN не мешает: наш работает поверх него (трафик к серверу идёт по маршрутам ОС, см. vpnUnderlay)
		fv := c.plat.ForeignVPN()
		if fv != g.lastForeign {
			g.event("vpn.over-foreign", "iface", fv, "mode", g.mode)
			g.lastForeign = fv
		}
		if fv == "" {
			g.resetSplit(ctx) // чужих маршрутов нет — нарезка не нужна (этап 1b)
		}
		wantVPN = true
	}
	if !wantVPN {
		g.split.Store(0)
		g.bypass = ""
	}

	// ЛВС (в общем sing-box вместе с каналом)
	wantLAN := false
	if !isNil(sb) && len(c.cfg.LAN) > 0 {
		nets, _ := singbox.LANSubnets(c.cfg)
		switch {
		case g.lanOff && reason != "net-changed" && reason != "vpn-cmd":
		case hasIface(ifs, "RA2-LAN"):
			g.lanState, g.lanWhy = "skipped-v2", "ЛВС уже держит Лаборатория v2 (RA2-LAN)"
			g.event("lan.skipped-v2")
		case len(nets) == 0:
			g.lanState, g.lanWhy = "no-subnets", "в конфиге нет подсетей клиники"
			g.event("lan.no-subnets")
		case c.getFw() == nil || c.getFw().InternalSocks() == "":
			g.lanState, g.lanWhy = "off", "нет внутреннего SOCKS"
		default:
			wantLAN = true
			g.lanOff = false
		}
	}

	var got api.Effective
	if !isNil(sb) {
		got.LAN = g.applyLAN(ctx, sb, reason, wantLAN)
	}
	vpnBad := ""
	if !isNil(vsb) {
		got.VPN, vpnBad = g.applyVPN(ctx, vsb, reason, wantVPN)
	}
	g.finish(got)
	if vpnBad != "" {
		g.failLocked(ctx, vpnBad)
		return
	}
	if wantVPN && got.VPN {
		go g.probe(ctx) // после успешной пробы — проверка выхода
	} else if reason == "net-changed" || reason == "foreign-changed" || reason == "vpn-cmd" {
		go g.checkExit(ctx, reason)
	}
}

// applyLAN — состояние ЛВС в общем sing-box; возвращает факт (поднят ли TUN ЛВС).
func (g *tunGuard) applyLAN(ctx context.Context, sb api.Singbox, reason string, want bool) bool {
	c := g.c
	if want != sb.Effective().LAN {
		actx, cancel := context.WithTimeout(ctx, 40*time.Second)
		err := sb.Apply(actx, api.Effective{LAN: want})
		cancel()
		if err != nil {
			c.log.Error("lan.apply-failed", "reason", reason, "err", err.Error())
			g.lanOff = g.lanOff || want
			g.lanState, g.lanWhy = "error", sanitize(err.Error())
			return sb.Effective().LAN
		}
	}
	got := sb.Effective().LAN
	if want {
		ifs, _ := c.plat.Interfaces()
		if !got || !hasIface(ifs, g.adapter("lan")) {
			g.lanOff, g.lanState, g.lanWhy = true, "error", "TUN ЛВС не поднялся (адаптера "+g.adapter("lan")+" нет)"
			c.log.Error("lan.tun-missing", "reason", reason)
			return false
		}
	}
	return got
}

// applyVPN — запуск/остановка процесса VPN; возвращает факт и причину неудачи ("" — нет).
func (g *tunGuard) applyVPN(ctx context.Context, vsb api.Singbox, reason string, want bool) (bool, string) {
	c := g.c
	if want != vsb.Effective().VPN {
		defer c.underlay() // старт/стоп нашего VPN меняет сеть под каналом
		actx, cancel := context.WithTimeout(ctx, 40*time.Second)
		err := vsb.Apply(actx, api.Effective{VPN: want})
		cancel()
		if err != nil && !want {
			// выключение обязано сработать (например, прошлая операция, переподключение при смене адаптера, держала замок): ещё одна попытка
			c.log.Error("vpn.stop-retry", "reason", reason, "err", err.Error())
			actx, cancel = context.WithTimeout(ctx, 40*time.Second)
			err = vsb.Apply(actx, api.Effective{VPN: false})
			cancel()
		}
		if err != nil {
			c.log.Error("vpn.apply-failed", "reason", reason, "err", err.Error())
			if want {
				return vsb.Effective().VPN, "apply: " + sanitize(err.Error())
			}
			return vsb.Effective().VPN, ""
		}
	}
	got := vsb.Effective().VPN
	if want {
		ifs, _ := c.plat.Interfaces()
		if !got || !hasIface(ifs, g.adapter("vpn")) {
			return false, "TUN VPN не поднялся (адаптера " + g.adapter("vpn") + " нет)"
		}
	}
	return got, ""
}

// finish — статусы по факту применённого состояния.
func (g *tunGuard) finish(got api.Effective) {
	if got.VPN {
		g.vpnState, g.vpnWhy = "up", ""
		g.underlay = g.c.vpnUnderlay()
	} else {
		g.underlay = ""
	}
	if got.LAN {
		g.lanState, g.lanWhy = "up", ""
	} else if g.lanState == "up" {
		g.lanState = "off"
	}
	g.event("vpn.state", "vpn", g.vpnState, "lan", g.lanState)
}

// tunExitOK — трафик к адресу пробы действительно выходит через наш vpn-адаптер.
func (g *tunGuard) tunExitOK() (string, bool) {
	out := g.c.plat.ExitIface(singbox.VPNProbeAddr)
	return out, out != "" && strings.EqualFold(out, g.adapter("vpn"))
}

// probe — одна проверка туннеля (после включения): запрос к адресу не из РФ идёт через TUN → vpn-out.
func (g *tunGuard) probe(ctx context.Context) {
	// Сначала факт маршрута: HTTP-проба мимо туннеля (провайдерский IP) ничего не доказывает.
	// Этап 1b: 14 проб по /4; мимо TUN часть — нарезка маршрутов; все мимо — сбой; часть мимо после нарезки — предупреждение.
	bad, out, handled := g.checkRoutes(ctx)
	if handled {
		return
	}
	if bad == len(probeAddrs) {
		g.mu.Lock()
		defer g.mu.Unlock()
		if g.vpnState == "foreign" || g.vpnState == "off" || g.mode == "off" {
			return
		}
		if out == "" {
			out = "не определён"
		}
		g.failLocked(ctx, "трафик к пробе идёт не через наш TUN (выход: "+out+")")
		return
	}
	if bad > 0 {
		g.setBypass(out)
	}
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
		go g.checkExit(ctx, "up")
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

// dropVPN — остановка процесса VPN (канал и ЛВС не трогаем). Горутина: под mu Apply не вызываем повторно.
func (g *tunGuard) dropVPN(ctx context.Context) {
	vsb := g.c.getVpnSb()
	if isNil(vsb) {
		return
	}
	go func() {
		actx, cancel := context.WithTimeout(ctx, 40*time.Second)
		defer cancel()
		if err := vsb.Apply(actx, api.Effective{}); err != nil {
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
	if g == nil || (isNil(c.getSb()) && isNil(c.getVpnSb())) {
		return
	}
	go g.reconcile(ctx, "start") // по конфигу; по умолчанию (vpn off, lan пуст) ничего не включается
}
