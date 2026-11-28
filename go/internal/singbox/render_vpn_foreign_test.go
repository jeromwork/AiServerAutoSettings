package singbox

import (
	"encoding/json"
	"strings"
	"testing"

	"remoteagents/internal/api"
)

func foreignRC(foreign bool, iface string) api.RenderContext {
	rc := vpnRC(false, false, iface)
	rc.Cfg.VPN.Nodes["n2"] = json.RawMessage(`{"type":"hysteria2","server":"203.0.113.8","server_port":443,"password":"p"}`)
	rc.Cfg.VPN.Nodes["n3"] = json.RawMessage(`{"type":"tuic","server":"203.0.113.9","server_port":443,"uuid":"u","password":"p"}`)
	rc.ForeignVPN = foreign
	return rc
}

func urltestOuts(t *testing.T, raw string) []string {
	t.Helper()
	var v struct {
		Outbounds []struct {
			Tag       string   `json:"tag"`
			Outbounds []string `json:"outbounds"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		t.Fatal(err)
	}
	for _, o := range v.Outbounds {
		if o.Tag == "vpn-out" {
			return o.Outbounds
		}
	}
	t.Fatal("нет vpn-out")
	return nil
}

func TestRenderVPNForeignKeepsUDPAndIface(t *testing.T) {
	v, raw := renderVPNOut(t, foreignRC(true, "happ-tun"))
	if got := urltestOuts(t, raw); len(got) != 3 {
		t.Fatalf("под чужим VPN UDP-мосты остаются (на ПК под Happ проходят hy2/tuic, TCP — нет), получили %v", got)
	}
	if strings.Contains(raw, "default_interface") || strings.Contains(raw, "auto_detect_interface") {
		t.Fatalf("под чужим VPN сокеты не привязываются к интерфейсу: %s", raw)
	}
	if !strings.Contains(raw, "route_exclude_address") {
		t.Fatalf("исключения серверов мостов из TUN должны остаться: %s", raw)
	}
	_ = v
	_, raw = renderVPNOut(t, foreignRC(false, "Wi-Fi"))
	if got := urltestOuts(t, raw); len(got) != 3 {
		t.Fatalf("без чужого VPN мосты прежние, получили %v", got)
	}
}

func TestVPNServerAddrFallbackToChannel(t *testing.T) {
	cfg := &api.Config{Servers: []api.Server{{Host: "203.0.113.5", Port: 22}}}
	if got := VPNServerAddr(cfg); got != "203.0.113.5:443" {
		t.Fatalf("адрес сервера канала, получили %q", got)
	}
	if got := VPNServerAddr(&api.Config{}); got != "" {
		t.Fatalf("нет ни узлов, ни канала: %q", got)
	}
}

// Причина «Работает поверх: Wi-Fi» под Happ: узлов vpn.nodes нет, мосты — пути канала; их серверы не попадали в
// route_exclude_address, после подъёма нашего TUN маршрут к ним вёл в наш адаптер и underlay становился физическим.
func TestRenderVPNExcludesChannelBridgeServers(t *testing.T) {
	rc := vpnRC(false, false, "happ-tun")
	rc.Cfg.VPN.Nodes = nil
	rc.Cfg.Servers = []api.Server{{Host: "203.0.113.5", Port: 22}}
	rc.Cfg.Paths.Channel = json.RawMessage(`{"outbounds":[{"type":"vless","server":"203.0.113.5","server_port":443,"uuid":"u"}]}`)
	_, raw := renderVPNOut(t, rc)
	if !strings.Contains(raw, `"203.0.113.5/32"`) {
		t.Fatalf("сервер моста канала должен быть в route_exclude_address: %s", raw)
	}
}

func TestRenderVPNNoForeignKeepsDefaultIface(t *testing.T) {
	_, raw := renderVPNOut(t, foreignRC(false, "Wi-Fi"))
	if !strings.Contains(raw, `"default_interface":"Wi-Fi"`) {
		t.Fatalf("без чужого VPN привязка к интерфейсу прежняя: %s", raw)
	}
	rc := foreignRC(false, "")
	_, raw = renderVPNOut(t, rc)
	if !strings.Contains(raw, `"auto_detect_interface":true`) {
		t.Fatalf("без интерфейса — auto_detect_interface: %s", raw)
	}
}

func TestDiagRedactHidesSecrets(t *testing.T) {
	var v any
	_ = json.Unmarshal([]byte(`{"outbounds":[{"type":"hysteria2","tag":"n","server":"203.0.113.8","password":"SECRET","uuid":"U"}]}`), &v)
	b, _ := json.Marshal(diagRedact(v, ""))
	got := string(b)
	if strings.Contains(got, "SECRET") || strings.Contains(got, `"U"`) || !strings.Contains(got, "203.0.113.8") {
		t.Fatalf("секреты скрыты, адрес виден: %s", got)
	}
}
