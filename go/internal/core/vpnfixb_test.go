package core

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
)

func newFixBCore(fv string) (*core, *fvSb, *fvPlat) {
	pl := &fvPlat{fv: fv}
	sb := &fvSb{}
	c := &core{log: &fake.Logger{}, plat: pl, vsb: sb, cfg: &api.Config{}}
	c.tun = &tunGuard{c: c, mode: "auto", vpnState: "off", lanState: "off", inst: "testinst"}
	return c, sb, pl
}

// Пункт 1: смена режима гасит отложенную пробу.
func TestSetModeStopsRetry(t *testing.T) {
	c, _, _ := newFixBCore("")
	g := c.tun
	g.retry = time.AfterFunc(time.Hour, func() {})
	g.setMode(context.Background(), "off")
	if g.retry.Stop() {
		t.Fatal("отложенная проба не остановлена setMode")
	}
}

// Пункт 2: чужой VPN попадает в статус.
func TestForeignInStatus(t *testing.T) {
	c, _, pl := newFixBCore("HappTun")
	g := c.tun
	g.reconcile(context.Background(), "start")
	if g.status()["foreign"] != "HappTun" {
		t.Fatalf("status: %v", g.status())
	}
	pl.fv = ""
	g.reconcile(context.Background(), "foreign-changed")
	if _, ok := g.status()["foreign"]; ok {
		t.Fatalf("foreign остался: %v", g.status())
	}
}

// Пункт 3: все пробы мимо TUN при чужом VPN — причина называет чужой VPN.
func TestAllBadProbesNameForeign(t *testing.T) {
	defer func(f func() (int, string)) { foreignRoutes = f }(foreignRoutes)
	foreignRoutes = func() (int, string) { return 0, "" }
	c, _, pl := newFixBCore("HappTun")
	pl.exit = "HappTun"
	g := c.tun
	g.vpnState, g.lastForeign = "up", "HappTun"
	g.probe(context.Background())
	if !strings.Contains(g.vpnWhy, "чужой VPN HappTun") {
		t.Fatalf("why=%q state=%s", g.vpnWhy, g.vpnState)
	}
}

// Пункт 4: сброс нарезки перезапускает VPN только если нарезка была.
func TestResetSplitOnlyWhenSplit(t *testing.T) {
	c, sb, _ := newFixBCore("")
	g := c.tun
	sb.eff.VPN = true
	g.resetSplit(context.Background())
	if sb.applied != 0 {
		t.Fatalf("лишний перезапуск: %d", sb.applied)
	}
	g.split.Store(9)
	g.resetSplit(context.Background())
	if sb.applied != 1 || g.split.Load() != 0 {
		t.Fatalf("applied=%d split=%d", sb.applied, g.split.Load())
	}
}

type clashSb struct {
	fvSb
	res  map[string]int
	err  error
	wait bool
	path string
}

func (s *clashSb) Clash(ctx context.Context, _, path string, _, out any) error {
	s.path = path
	if s.wait {
		<-ctx.Done()
		return ctx.Err()
	}
	if s.err != nil {
		return s.err
	}
	*(out.(*map[string]int)) = s.res
	return nil
}

// Проба ждёт замер мостов urltest (ответ группы), а не фиксированные секунды на первый мост.
func TestWaitBridges(t *testing.T) {
	defer func(d time.Duration) { vpnBridgeWait = d }(vpnBridgeWait)
	vpnBridgeWait = 50 * time.Millisecond
	c, _, _ := newFixBCore("")
	for _, tc := range []struct {
		name string
		sb   *clashSb
		bad  bool
	}{
		{"ok", &clashSb{res: map[string]int{"a": 0, "b": 120}}, false},
		{"none", &clashSb{res: map[string]int{"a": 0}}, true},
		{"status", &clashSb{err: errors.New("singbox: clash-status: HTTP 504")}, true},
		{"timeout", &clashSb{wait: true}, true},
		{"clash-down", &clashSb{err: errors.New("singbox: clash-connect: request failed")}, false},
	} {
		c.vsb = tc.sb
		why := c.tun.waitBridges(context.Background())
		if (why != "") != tc.bad || !strings.Contains(tc.sb.path, "/group/vpn-out/delay") {
			t.Fatalf("%s: why=%q path=%q", tc.name, why, tc.sb.path)
		}
	}
}
