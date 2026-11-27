//go:build linux

package platform

import (
	"context"
	"strings"
	"testing"
)

func fakeSweep(t *testing.T, procs []sweepProc, tables, rules string) *[]string {
	t.Helper()
	var calls []string
	oldE, oldC, oldR := sweepExec, sweepProcs, sweepReadFile
	t.Cleanup(func() { sweepExec, sweepProcs, sweepReadFile = oldE, oldC, oldR })
	sweepProcs = func() []sweepProc { return procs }
	sweepReadFile = func(p string) ([]byte, error) {
		if strings.Contains(p, "tun") {
			return []byte(`{"inbounds":[{"type":"tun"}]}`), nil
		}
		return []byte(`{"inbounds":[{"type":"mixed"}]}`), nil
	}
	sweepExec = func(_ context.Context, name string, args ...string) ([]byte, error) {
		cmd := name + " " + strings.Join(args, " ")
		calls = append(calls, cmd)
		switch {
		case strings.HasPrefix(cmd, "nft list tables"):
			return []byte(tables), nil
		case strings.HasSuffix(cmd, "rule show"):
			if strings.HasPrefix(cmd, "ip -4") {
				return []byte(rules), nil
			}
		}
		return nil, nil
	}
	return &calls
}

const fakeTables = "table inet sing-box\ntable inet other\n"
const fakeRules = "0:\tfrom all lookup local\n9000:\tfrom all lookup 2022\n9001:\tfrom all unreachable\n32766:\tfrom all lookup main\n"

// Процесса VPN нет (убит, выключен) — таблица sing-box и ip rule 9000–9010 убраны, чужое не тронуто.
func TestSweepVPNLockRemovesLeftovers(t *testing.T) {
	calls := fakeSweep(t, []sweepProc{{comm: "bash"}}, fakeTables, fakeRules)
	if err := SweepVPNLock(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := strings.Join(*calls, "|")
	for _, want := range []string{"nft delete table inet sing-box", "ip -4 rule del pref 9000", "ip -4 rule del pref 9001"} {
		if !strings.Contains(got, want) {
			t.Fatalf("нет %q: %s", want, got)
		}
	}
	if strings.Contains(got, "other") || strings.Contains(got, "pref 0") || strings.Contains(got, "32766") {
		t.Fatalf("тронуто чужое: %s", got)
	}
}

// Живой ra-vpn — его правила, не трогаем; живой ra-core — не трогаем ip rule.
func TestSweepVPNLockKeepsLive(t *testing.T) {
	calls := fakeSweep(t, []sweepProc{{"ra-vpn", []string{"ra-vpn", "run", "-c", "/x/vpn-tun.json"}}}, fakeTables, fakeRules)
	_ = SweepVPNLock(context.Background())
	for _, c := range *calls {
		if strings.Contains(c, "delete") || strings.Contains(c, "del") {
			t.Fatalf("тронуто при живом VPN: %s", c)
		}
	}
	calls = fakeSweep(t, []sweepProc{{"ra-core", []string{"ra-core", "run", "-c", "/x/lan-tun.json"}}}, fakeTables, fakeRules)
	_ = SweepVPNLock(context.Background())
	got := strings.Join(*calls, "|")
	if !strings.Contains(got, "nft delete table inet sing-box") || strings.Contains(got, "rule del") {
		t.Fatalf("ra-core: %s", got)
	}
}

// Жив канальный sing-box (ra-core без TUN), VPN убит: таблица и ip rule убираются (иначе интернет остался бы перекрыт).
func TestSweepVPNLockChannelBoxDoesNotBlock(t *testing.T) {
	calls := fakeSweep(t, []sweepProc{{"ra-core", []string{"ra-core", "run", "-c", "/x/channel.json"}}}, fakeTables, fakeRules)
	if err := SweepVPNLock(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := strings.Join(*calls, "|")
	if !strings.Contains(got, "nft delete table inet sing-box") || !strings.Contains(got, "rule del pref 9000") {
		t.Fatalf("канальный sing-box заблокировал уборку: %s", got)
	}
	// Чужой sing-box без TUN тоже не держит правил; с TUN — держит.
	calls = fakeSweep(t, []sweepProc{{"sing-box", []string{"sing-box", "run", "-c", "/e/a.json"}}}, fakeTables, fakeRules)
	_ = SweepVPNLock(context.Background())
	if !strings.Contains(strings.Join(*calls, "|"), "nft delete") {
		t.Fatal("чужой sing-box без TUN не должен блокировать")
	}
	calls = fakeSweep(t, []sweepProc{{"sing-box", []string{"sing-box", "run", "-c", "/e/tun.json"}}}, fakeTables, fakeRules)
	_ = SweepVPNLock(context.Background())
	if strings.Contains(strings.Join(*calls, "|"), "del") {
		t.Fatal("чужой sing-box с TUN трогать нельзя")
	}
}
