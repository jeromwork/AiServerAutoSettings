package singbox

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"remoteagents/internal/api"
)

func vpnRC(lock, block bool, iface string) api.RenderContext {
	return api.RenderContext{
		Cfg: &api.Config{VPN: api.VPNCfg{
			LockExit: lock,
			Direct:   api.VPNDirect{Domains: []string{"example.ru"}},
			Nodes:    map[string]json.RawMessage{"n1": json.RawMessage(`{"type":"vless","server":"203.0.113.7","server_port":443,"uuid":"u"}`)},
		}},
		Instance: "0123456789abcdef0123456789abcdef", ClashPort: 9090, ClashSecret: "s",
		VPNBlock: block, DefaultIface: iface,
	}
}

type vpnOut struct {
	Inbounds []map[string]any `json:"inbounds"`
	Route    struct {
		Final string           `json:"final"`
		Rules []map[string]any `json:"rules"`
	} `json:"route"`
}

func renderVPNOut(t *testing.T, rc api.RenderContext) (vpnOut, string) {
	t.Helper()
	rc.GeoIPPath = filepath.Join(t.TempDir(), "geoip-ru.srs")
	if err := os.WriteFile(rc.GeoIPPath, []byte("x"), 0600); err != nil {
		t.Fatal(err)
	}
	b, err := RenderVPN(rc)
	if err != nil {
		t.Fatal(err)
	}
	var v vpnOut
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	return v, string(b)
}

// Без галочки поведение прежнее: РФ и домены напрямую, strict_route выключен, ничего не отклоняется.
func TestRenderVPNNoLock(t *testing.T) {
	v, raw := renderVPNOut(t, vpnRC(false, true, ""))
	if v.Inbounds[0]["strict_route"] != false || !strings.Contains(raw, "geoip-ru") || !strings.Contains(raw, "example.ru") || strings.Contains(raw, `"reject"`) {
		t.Fatalf("без галочки: %s", raw)
	}
}

// Галочка: strict_route, нет прямых исключений РФ/доменов, приватные и процессы канала остаются напрямую (канал и страница 127.0.0.1 живы).
func TestRenderVPNLock(t *testing.T) {
	v, raw := renderVPNOut(t, vpnRC(true, false, ""))
	if v.Inbounds[0]["strict_route"] != true || strings.Contains(raw, "geoip-ru") || strings.Contains(raw, "example.ru") {
		t.Fatalf("галочка: %s", raw)
	}
	if !strings.Contains(raw, `"ip_is_private":true`) || !strings.Contains(raw, "ra-lab") || !strings.Contains(raw, "127.0.0.0/8") || !strings.Contains(raw, "203.0.113.7/32") {
		t.Fatalf("исключения канала/страницы/узла потеряны: %s", raw)
	}
	if strings.Contains(raw, `"reject"`) || v.Route.Final != "vpn-out" {
		t.Fatalf("без перекрытия отклонять нельзя: %s", raw)
	}
}

// Перекрыто: reject последним правилом (после исключений), перед ним — свой процесс через vpn-out для проверки выхода.
func TestRenderVPNBlocked(t *testing.T) {
	v, raw := renderVPNOut(t, vpnRC(true, true, ""))
	n := len(v.Route.Rules)
	if n < 3 || v.Route.Rules[n-1]["action"] != "reject" || v.Route.Rules[n-1]["inbound"] == nil {
		t.Fatalf("последнее правило должно отклонять трафик из TUN: %s", raw)
	}
	if v.Route.Rules[n-2]["outbound"] != "vpn-out" || v.Route.Rules[n-2]["process_name"] == nil {
		t.Fatalf("свой процесс должен идти через vpn-out: %s", raw)
	}
	if v.Route.Rules[0]["outbound"] != "vpn-direct" || !strings.Contains(raw, "ra-lab") {
		t.Fatalf("процессы канала должны остаться первыми и напрямую: %s", raw)
	}
	// Перекрытие — только вместе с галочкой.
	_, raw = renderVPNOut(t, vpnRC(false, true, ""))
	if strings.Contains(raw, `"reject"`) {
		t.Fatal("без галочки перекрытие не рендерится")
	}
}

// Linux + галочка: sing-box сам ставит nft (auto_redirect) вместе со strict_route; без галочки или вне Linux — нет.
func TestRenderVPNAutoRedirectLinuxOnly(t *testing.T) {
	old := vpnGOOS
	defer func() { vpnGOOS = old }()
	for _, c := range []struct {
		goos string
		lock bool
		want bool
	}{{"linux", true, true}, {"linux", false, false}, {"windows", true, false}, {"darwin", true, false}} {
		vpnGOOS = c.goos
		v, _ := renderVPNOut(t, vpnRC(c.lock, false, ""))
		got, _ := v.Inbounds[0]["auto_redirect"].(bool)
		if got != c.want {
			t.Fatalf("%s lock=%v: auto_redirect=%v", c.goos, c.lock, got)
		}
	}
}

func procRuleIdx(rules []map[string]any, name, outbound string) int {
	for i, r := range rules {
		l, _ := r["process_name"].([]any)
		for _, x := range l {
			if x == name && r["outbound"] == outbound {
				return i
			}
		}
	}
	return -1
}

// Имена, под которыми запускаются ядра (все ОС), обязаны быть в правиле process_name: иначе переименование бинаря снова зациклит канал через VPN.
func TestRenderVPNOwnProcsListed(t *testing.T) {
	v, _ := renderVPNOut(t, vpnRC(true, false, ""))
	for _, n := range []string{coreNameWin, coreNameNix, vpnNameWin, vpnNameNix, binaryName(), vpnBinaryName()} {
		if procRuleIdx(v.Route.Rules, n, "vpn-direct") < 0 {
			t.Fatalf("%s нет в process_name direct", n)
		}
	}
}

// Галочка: ra-core.exe -> direct раньше любого правила в vpn-out/reject.
func TestRenderVPNLockCoreDirectFirst(t *testing.T) {
	for _, block := range []bool{false, true} {
		v, raw := renderVPNOut(t, vpnRC(true, block, ""))
		i := procRuleIdx(v.Route.Rules, "ra-core.exe", "vpn-direct")
		if i != 0 {
			t.Fatalf("block=%v: ra-core.exe direct на позиции %d: %s", block, i, raw)
		}
		for j, r := range v.Route.Rules {
			if (r["outbound"] == "vpn-out" || r["action"] == "reject") && j < i {
				t.Fatalf("правило %d раньше direct", j)
			}
		}
	}
}

// Блок-режим: свой процесс программы -> vpn-out, затем финальный reject; ra-core остаётся direct.
func TestRenderVPNLockBlockSelfThenReject(t *testing.T) {
	v, raw := renderVPNOut(t, vpnRC(true, true, ""))
	self := selfProcName()
	si := procRuleIdx(v.Route.Rules, self, "vpn-out")
	last := v.Route.Rules[len(v.Route.Rules)-1]
	if si < 0 || last["action"] != "reject" || procRuleIdx(v.Route.Rules, "ra-core.exe", "vpn-direct") < 0 {
		t.Fatalf("блок: %s", raw)
	}
}
