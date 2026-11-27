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
