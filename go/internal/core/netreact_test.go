package core

import (
	"context"
	"errors"
	"testing"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
)

func TestDebounceCoalescesBurst(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	in := make(chan struct{})
	out := debounce(ctx, in, 50*time.Millisecond)
	for i := 0; i < 20; i++ {
		in <- struct{}{}
		time.Sleep(2 * time.Millisecond)
	}
	select {
	case <-out:
	case <-time.After(2 * time.Second):
		t.Fatal("нет события после тишины")
	}
	select {
	case <-out:
		t.Fatal("пачка не слита в одно событие")
	case <-time.After(120 * time.Millisecond):
	}
}

func wifi(addr string) api.Iface {
	return api.Iface{Name: "Wi-Fi", Up: true, DefaultRoute: true, Metric: 30, Addrs: []string{addr}}
}

// Tailscale/Happ/Hyper-V меняют адреса и маршруты постоянно — отпечаток физической сети не меняется.
func TestNetSignatureIgnoresForeignAdapters(t *testing.T) {
	ts := api.Iface{Name: "Tailscale", Up: true, DefaultRoute: true, Metric: 1, Addrs: []string{"100.64.0.1"}}
	a := netSignature([]api.Iface{wifi("192.168.1.5"), ts})
	ts.Addrs = []string{"100.64.0.9"}
	b := netSignature([]api.Iface{wifi("192.168.1.5"), ts, {Name: "happ-tun", Up: true, DefaultRoute: true, Metric: 0, Addrs: []string{"10.1.1.1"}}})
	if a != b || a == "" {
		t.Fatalf("a=%q b=%q", a, b)
	}
	if c := netSignature([]api.Iface{wifi("10.0.0.7")}); c == a {
		t.Fatal("смена адреса физического адаптера не замечена")
	}
}

func TestNetReactRebuildsOnlyOnRealChange(t *testing.T) {
	sig, up := "wifi|1", true
	var sb, ch int
	n := &netReact{log: &fake.Logger{}, sig: func() string { return sig }, chUp: func() bool { return up },
		sbReset: func(context.Context) { sb++ }, chReset: func() { ch++ }}
	n.last, n.inited = sig, true
	if n.onChange(context.Background()) || sb+ch != 0 {
		t.Fatal("лишняя перестройка при той же сети и живом канале")
	}
	sig = "eth|2" // Wi-Fi → другая сеть
	if !n.onChange(context.Background()) || sb != 1 || ch != 1 {
		t.Fatalf("смена сети не обработана sb=%d ch=%d", sb, ch)
	}
	up = false // канал лежит, но сеть та же — событие без реальной смены не перестраивает (сбой 27.11)
	if n.onChange(context.Background()) || sb != 1 || ch != 1 {
		t.Fatalf("перестройка без смены сети sb=%d ch=%d", sb, ch)
	}
}

type fvPlat struct {
	api.Platform
	fv        string
	noAdapter bool
	exit      string
}

func (p *fvPlat) Interfaces() ([]api.Iface, error) {
	ifs := []api.Iface{wifi("192.168.1.5")}
	if !p.noAdapter {
		ifs = append(ifs, api.Iface{Name: "ra3-testinst-vpn", Up: true})
	}
	return ifs, nil
}
func (p *fvPlat) SystemProxy() api.SysProxy { return api.SysProxy{} }
func (p *fvPlat) ForeignVPN() string        { return p.fv }
func (p *fvPlat) ExitIface(string) string {
	if p.exit != "" {
		return p.exit
	}
	return "ra3-testinst-vpn"
}

type fvSb struct {
	api.Singbox
	eff     api.Effective
	applied int
}

func (s *fvSb) Effective() api.Effective { return s.eff }
func (s *fvSb) Status() map[string]any   { return map[string]any{} }
func (s *fvSb) Apply(_ context.Context, e api.Effective) error {
	s.eff = e
	s.applied++
	return nil
}

// Чужой VPN выключили/включили при той же физической сети и живом канале: наш VPN поднимается/снимается, канал не сбрасывается.
func TestForeignVPNChangeReconcilesWithoutChannelReset(t *testing.T) {
	plat := &fvPlat{fv: "HappTun"}
	sb := &fvSb{}
	c := &core{log: &fake.Logger{}, plat: plat, vsb: sb, cfg: &api.Config{}}
	c.tun = &tunGuard{c: c, mode: "auto", vpnState: "off", lanState: "off", inst: "testinst"}
	ctx := context.Background()
	c.tun.reconcile(ctx, "start")
	if !sb.eff.VPN || c.tun.vpnState != "up" {
		t.Fatalf("наш VPN должен подниматься поверх чужого: %+v %s", sb.eff, c.tun.vpnState)
	}
	var chReset int
	n := &netReact{log: c.log, sig: func() string { return "wifi|1" }, chUp: func() bool { return true },
		chReset: func() { chReset++ }, foreign: plat.ForeignVPN}
	n.last, n.inited, n.lastFV, n.fvInit = "wifi|1", true, "HappTun", true

	if n.onChange(ctx) || n.foreignChanged() {
		t.Fatal("ничего не менялось, а реакция есть")
	}
	plat.fv = "" // чужой выключили
	if n.onChange(ctx) || !n.foreignChanged() {
		t.Fatal("выключение чужого VPN не замечено")
	}
	c.tun.reconcile(ctx, "foreign-changed")
	if !sb.eff.VPN || c.tun.vpnState != "up" {
		t.Fatalf("наш VPN не поднялся: %+v %s", sb.eff, c.tun.vpnState)
	}
	plat.fv = "HappTun" // включили
	if !n.foreignChanged() {
		t.Fatal("появление чужого VPN не замечено")
	}
	c.tun.reconcile(ctx, "foreign-changed")
	if !sb.eff.VPN || c.tun.vpnState != "up" {
		t.Fatalf("наш VPN должен остаться поверх чужого: %+v %s", sb.eff, c.tun.vpnState)
	}
	if chReset != 0 {
		t.Fatalf("канал сброшен %d раз", chReset)
	}
}

func newVerifyCore(plat *fvPlat) (*core, *fvSb) {
	sb := &fvSb{}
	c := &core{log: &fake.Logger{}, plat: plat, vsb: sb, cfg: &api.Config{}}
	c.tun = &tunGuard{c: c, mode: "auto", vpnState: "off", lanState: "off", inst: "testinst"}
	return c, sb
}

// Apply «успешен», а адаптера нет (sing-box откатился без TUN) — это не up, а vpn.fail.
func TestApplyOkButNoAdapterIsFail(t *testing.T) {
	c, sb := newVerifyCore(&fvPlat{noAdapter: true})
	c.tun.reconcile(context.Background(), "start")
	if sb.applied != 1 || c.tun.vpnState == "up" || c.tun.fails != 1 || c.tun.vpnState != "error" {
		t.Fatalf("state=%s fails=%d why=%q", c.tun.vpnState, c.tun.fails, c.tun.vpnWhy)
	}
}

// Apply вернул nil, но sing-box фактически без TUN (Effective пуст) — не up.
func TestApplyFellBackWithoutTunIsFail(t *testing.T) {
	c, _ := newVerifyCore(&fvPlat{})
	c.vsb = &fellBackSb{}
	c.tun.reconcile(context.Background(), "start")
	if c.tun.vpnState == "up" || c.tun.fails != 1 {
		t.Fatalf("state=%s fails=%d", c.tun.vpnState, c.tun.fails)
	}
}

type fellBackSb struct{ fvSb }

func (s *fellBackSb) Apply(context.Context, api.Effective) error { return nil }

// Интерфейс выхода пробы не наш — проба неудачна, HTTP не нужен.
func TestProbeFailsWhenExitIfaceNotOurs(t *testing.T) {
	defer func(f func() (int, string)) { foreignRoutes = f }(foreignRoutes)
	foreignRoutes = func() (int, string) { return 0, "" }
	c, _ := newVerifyCore(&fvPlat{exit: "Ethernet"})
	c.tun.vpnState = "up"
	c.tun.probe(context.Background())
	if c.tun.fails != 1 || c.tun.vpnState != "error" {
		t.Fatalf("state=%s fails=%d why=%q", c.tun.vpnState, c.tun.fails, c.tun.vpnWhy)
	}
}

func TestOnForeignResetsSingboxAndUnderlay(t *testing.T) {
	var sb, ul int
	n := &netReact{log: &fake.Logger{}, sbReset: func(context.Context) { sb++ }}
	n.onForeign(context.Background(), func() { ul++ })
	if sb != 1 || ul != 1 {
		t.Fatalf("sbReset=%d underlay=%d, ждали по 1", sb, ul)
	}
}

func TestResilientWatchReopensAfterClose(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	opens := 0
	open := func(context.Context) <-chan struct{} {
		opens++
		ch := make(chan struct{}, 1)
		if opens == 1 {
			close(ch) // первый сокет умер сразу
		}
		return ch
	}
	out := resilientWatch(ctx, &fake.Logger{}, open, 10*time.Millisecond)
	select {
	case <-out: // событие после переоткрытия
	case <-time.After(2 * time.Second):
		t.Fatal("WatchNet не переоткрыт")
	}
	if opens != 2 {
		t.Fatalf("opens=%d, ждали 2", opens)
	}
	cancel()
	select {
	case _, ok := <-out:
		if ok {
			<-out
		}
	case <-time.After(2 * time.Second):
		t.Fatal("канал не закрылся по ctx")
	}
}

// Наши адаптеры (ra3-*), поднятые с маршрутом по умолчанию 0/1, не меняют отпечаток и не считаются чужим VPN.
func TestNetSignatureIgnoresOurTun(t *testing.T) {
	a := netSignature([]api.Iface{wifi("192.168.1.5")})
	our := api.Iface{Name: "ra3-0123abcd-vpn", Up: true, DefaultRoute: true, Metric: 0, Addrs: []string{"172.19.0.1"}}
	lan := api.Iface{Name: "ra3-0123abcd-lan", Up: true, DefaultRoute: true, Metric: 0, Addrs: []string{"172.19.9.1"}}
	if b := netSignature([]api.Iface{wifi("192.168.1.5"), our, lan}); a != b || a == "" {
		t.Fatalf("a=%q b=%q", a, b)
	}
}

func (s *fvSb) Clash(context.Context, string, string, any, any) error {
	return errors.New("singbox: clash-connect: request failed")
}
