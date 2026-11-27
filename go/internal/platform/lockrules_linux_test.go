//go:build linux

package platform

import (
	"context"
	"strings"
	"testing"
)

func fakeSweep(t *testing.T, comms []string, tables, rules string) *[]string {
	t.Helper()
	var calls []string
	oldE, oldC := sweepExec, sweepComms
	t.Cleanup(func() { sweepExec, sweepComms = oldE, oldC })
	sweepComms = func() []string { return comms }
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
	calls := fakeSweep(t, []string{"bash"}, fakeTables, fakeRules)
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
	calls := fakeSweep(t, []string{"ra-vpn"}, fakeTables, fakeRules)
	_ = SweepVPNLock(context.Background())
	for _, c := range *calls {
		if strings.Contains(c, "delete") || strings.Contains(c, "del") {
			t.Fatalf("тронуто при живом VPN: %s", c)
		}
	}
	calls = fakeSweep(t, []string{"ra-core"}, fakeTables, fakeRules)
	_ = SweepVPNLock(context.Background())
	got := strings.Join(*calls, "|")
	if !strings.Contains(got, "nft delete table inet sing-box") || strings.Contains(got, "rule del") {
		t.Fatalf("ra-core: %s", got)
	}
}
