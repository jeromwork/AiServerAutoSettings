package core

import (
	"context"
	"testing"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/singbox"
)

// splitPlat — чужой VPN держит /8: пока нарезка меньше /9, половина проб уходит в чужой адаптер.
type splitPlat struct {
	fvPlat
	g *tunGuard
}

func (p *splitPlat) ExitIface(a string) string {
	if p.g.split.Load() < 9 && a != probeAddrs[0] {
		return "HappTun"
	}
	return "ra3-testinst-vpn"
}

func newSplitCore(p *splitPlat) (*core, *fvSb) {
	sb := &fvSb{}
	c := &core{log: &fake.Logger{}, plat: p, vsb: sb, cfg: &api.Config{}}
	c.tun = &tunGuard{c: c, mode: "auto", vpnState: "off", lanState: "off", inst: "testinst"}
	p.g = c.tun
	return c, sb
}

func TestSweepSplitsAndRestartsOnce(t *testing.T) {
	defer func(f func() (int, string)) { foreignRoutes = f }(foreignRoutes)
	foreignRoutes = func() (int, string) { return 8, "HappTun" }
	pl := &splitPlat{}
	c, sb := newSplitCore(pl)
	pl.g = c.tun
	c.tun.vpnState = "up"
	sb.eff.VPN = true
	bad, _, handled := c.tun.checkRoutes(context.Background())
	if bad != 0 || handled || c.tun.split.Load() != 9 || sb.applied != 1 {
		t.Fatalf("bad=%d handled=%v split=%d applied=%d", bad, handled, c.tun.split.Load(), sb.applied)
	}
	if c.tun.statusLocked()["split"] != "/9" {
		t.Fatalf("status: %v", c.tun.statusLocked())
	}
}

// Чужой VPN держит /32 (L не определён): нарезка не помогает — предупреждение bypass, VPN не выключается.
func TestSweepBypassWarning(t *testing.T) {
	defer func(f func() (int, string)) { foreignRoutes = f }(foreignRoutes)
	foreignRoutes = func() (int, string) { return 0, "" }
	pl := &splitPlat{}
	c, sb := newSplitCore(pl)
	pl.g = c.tun
	c.tun.vpnState = "up"
	c.tun.probe(context.Background())
	if c.tun.bypass != "HappTun" || c.tun.vpnState != "up" || c.tun.fails != 0 || sb.applied != 0 {
		t.Fatalf("bypass=%q state=%s fails=%d applied=%d", c.tun.bypass, c.tun.vpnState, c.tun.fails, sb.applied)
	}
}

func TestSplitRoutes(t *testing.T) {
	if r := singbox.SplitRoutes(0); len(r) != 4 || r[0] != "0.0.0.0/1" {
		t.Fatal(r)
	}
	r := singbox.SplitRoutes(9)
	if len(r) != 512+64 || r[0] != "0.0.0.0/9" || r[511] != "255.128.0.0/9" || r[512] != "2000::/9" {
		t.Fatal(len(r), r[0], r[511], r[512])
	}
}
