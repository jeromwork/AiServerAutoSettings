package singbox

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"sort"
	"strings"
	"time"

	"remoteagents/internal/api"
)

// AdapterName — имя TUN-адаптера нашего экземпляра: часть "vpn" или "lan". Совпадает с проверкой владения в cleanup.
func AdapterName(instance, part string) string {
	if len(instance) < 8 {
		return ""
	}
	return "ra3-" + instance[:8] + "-" + part
}

var vpnExclude = []string{
	"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "127.0.0.0/8", "224.0.0.0/4",
	"255.255.255.255/32", "1.1.1.1/32", "fc00::/7", "fe80::/10", "ff00::/8",
}

// vpnAlwaysDirect — адреса, которые никогда не идут через наш VPN (канал — слой поверх сети, исключений для него нет).
var vpnAlwaysDirect = []string{}

// vpnDirectProcs — процессы, трафик которых идёт мимо нашего VPN: v2 Лаборатория (ra-lab, её sing-box) и чужие VPN.
var vpnDirectProcs = []string{
	"ra-lab.exe", "ra-lab", "ralab-core.exe", "ralab-core", "ralab.exe", "sing-box.exe", "sing-box",
	"RemoteAgents-VPN.exe", "ra-vpn",
	"Happ.exe", "happ.exe", "xray.exe", "v2rayN.exe", "tailscaled.exe", "Tailscale.exe",
}

// VPNProbeURL — адрес проверки туннеля (не РФ → всегда через vpn-out).
// VPNProbeAddr — адрес для проверки интерфейса выхода (не РФ, не в исключениях vpnExclude → по маршрутам идёт в наш TUN).
const VPNProbeAddr = "8.8.8.8:53"

const VPNProbeURL = "https://www.gstatic.com/generate_204"

// resolveHost — IP узла для исключения из TUN; имена — через системный DNS с пределом 3 с (событийно: только при сборке конфига).
func resolveHost(host string) []string {
	if ip, err := netip.ParseAddr(host); err == nil {
		return []string{ip.String()}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	addrs, err := net.DefaultResolver.LookupHost(ctx, host)
	if err != nil {
		return nil
	}
	return addrs
}

// vpnSel — мосты VPN: outbounds процесса, теги для urltest и хосты, которые не должны идти в наш TUN.
type vpnSel struct {
	outs   []m
	finals []string
	hosts  []string
}

// vpnSelect — мосты из vpn.nodes (узлы целиком) и из путей paths (если есть сервер) по vpn.bridges (пусто — все),
// без ssh/direct/socks и без путей «через чужой VPN». Узел с тем же именем, что и путь, главнее.
func vpnSelect(cfg *api.Config) (vpnSel, error) {
	var sel vpnSel
	want := map[string]bool{}
	for _, b := range cfg.VPN.Bridges {
		want[b] = true
	}
	hosts := map[string]bool{}
	seenTag := map[string]bool{}
	seenFinal := map[string]bool{}
	keep := func(o m) m {
		o = cloneM(o)
		if t, _ := o["type"].(string); tcpTypes[t] && o["detour"] == nil {
			o["tcp_keep_alive"], o["tcp_keep_alive_interval"] = "15s", "5s"
		}
		return o
	}
	names := make([]string, 0, len(cfg.VPN.Nodes))
	for n := range cfg.VPN.Nodes {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		o, err := decodeObj(cfg.VPN.Nodes[n])
		if err != nil {
			return sel, fmt.Errorf("singbox: vpn: узел %s: %w", n, err)
		}
		t, _ := o["type"].(string)
		if t == "" || t == "direct" || t == "block" || t == "dns" || t == "selector" || t == "urltest" {
			return sel, fmt.Errorf("singbox: vpn: узел %s: тип %q не подходит", n, t)
		}
		o["tag"] = n
		if s, _ := o["server"].(string); s != "" {
			hosts[s] = true
		}
		seenTag[n] = true
		if len(want) > 0 && !want[n] {
			continue
		}
		seenFinal[n] = true
		sel.outs = append(sel.outs, keep(o))
		sel.finals = append(sel.finals, n)
	}
	if cfg.HasChannel() {
		paths, _, err := buildPaths(cfg, cfg.Servers[0].Host)
		if err != nil {
			return sel, err
		}
		for _, p := range paths {
			bad := strings.HasSuffix(p.final, "-vpn") || seenFinal[p.final] || seenTag[p.final]
			for _, o := range p.outs {
				if t, _ := o["type"].(string); t == "ssh" || t == "direct" || t == "socks" {
					bad = true
				}
			}
			if bad || (len(want) > 0 && !want[p.name]) {
				continue
			}
			seenFinal[p.final] = true
			for _, o := range p.outs {
				tag, _ := o["tag"].(string)
				if seenTag[tag] && tag != p.final {
					continue // общий узел цепочки уже добавлен
				}
				seenTag[tag] = true
				sel.outs = append(sel.outs, keep(o))
			}
			sel.finals = append(sel.finals, p.final)
		}
	}
	for h := range hosts {
		if h != "" {
			sel.hosts = append(sel.hosts, h)
		}
	}
	sort.Strings(sel.hosts)
	return sel, nil
}

// excludeSet — route_exclude_address: приватные сети, серверы/узлы из конфига, always-direct, rc.ExcludeIPs.
func excludeSet(rc api.RenderContext, hosts []string) []string {
	out := append([]string(nil), vpnExclude...)
	seen := map[string]bool{}
	for _, v := range out {
		seen[v] = true
	}
	add := func(v string) {
		if ip, err := netip.ParseAddr(v); err == nil {
			v = netip.PrefixFrom(ip.WithZone(""), ip.BitLen()).String()
		}
		if _, err := netip.ParsePrefix(v); err == nil && !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	for _, v := range vpnAlwaysDirect {
		add(v)
	}
	for _, v := range rc.ExcludeIPs {
		add(v)
	}
	for _, h := range hosts {
		for _, a := range resolveHost(h) {
			add(a)
		}
	}
	return out
}

// RenderVPN — конфиг ОТДЕЛЬНОГО процесса sing-box VPN (tun-in ra3-<id>-vpn, urltest по мостам, РФ напрямую):
// sniff → процессы v2/чужих VPN → приватные → domain_suffix → rule_set geoip-ru. Выход к мостам — напрямую через физический
// интерфейс (default_interface / auto_detect_interface), не через sing-box канала. Режимы off/auto/only различаются в сторожe (core).
func RenderVPN(rc api.RenderContext) ([]byte, error) {
	if rc.Cfg == nil {
		return nil, errors.New("singbox: vpn: no config")
	}
	if rc.ClashPort <= 0 {
		return nil, errors.New("singbox: vpn: ports are not set")
	}
	sel, err := vpnSelect(rc.Cfg)
	if err != nil {
		return nil, err
	}
	if len(sel.finals) == 0 {
		return nil, errors.New("singbox: vpn: нет мостов без SSH и прямых выходов")
	}
	name := AdapterName(rc.Instance, "vpn")
	if name == "" {
		return nil, errors.New("singbox: vpn: instance")
	}
	rules := []m{
		{"process_name": vpnDirectProcs, "outbound": "vpn-direct"},
		{"action": "sniff"},
		{"ip_is_private": true, "outbound": "vpn-direct"},
	}
	var suffixes []string
	for _, d := range rc.Cfg.VPN.Direct.Domains {
		if strings.Trim(d, ". ") != "" {
			suffixes = append(suffixes, vpnIDNA(d))
		}
	}
	if len(suffixes) > 0 {
		rules = append(rules, m{"domain_suffix": suffixes, "outbound": "vpn-direct"})
	}
	route := m{"auto_detect_interface": true, "find_process": true, "final": "vpn-out"}
	if rc.DefaultIface != "" {
		delete(route, "auto_detect_interface")
		route["default_interface"] = rc.DefaultIface
	}
	if rc.GeoIPPath != "" && vpnGeoIP(rc.Cfg.VPN.Direct.GeoIP) {
		if st, err := os.Stat(rc.GeoIPPath); err == nil && st.Mode().IsRegular() {
			rules = append(rules, m{"rule_set": []string{"geoip-ru"}, "outbound": "vpn-direct"})
			route["rule_set"] = []m{{"type": "local", "tag": "geoip-ru", "format": "binary", "path": rc.GeoIPPath}}
		}
	}
	route["rules"] = rules
	tun := m{"type": "tun", "tag": "vpn-in", "interface_name": name,
		"address": []string{"172.19.8.1/30", "fdfe:dcba:9877::1/126"}, "mtu": 1400,
		"auto_route": true, "strict_route": false,
		"route_address":         []string{"0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"},
		"route_exclude_address": excludeSet(rc, sel.hosts)}
	outs := append([]m(nil), sel.outs...)
	outs = append(outs,
		m{"type": "urltest", "tag": "vpn-out", "outbounds": sel.finals, "url": VPNProbeURL, "interval": "3m", "tolerance": 100, "interrupt_exist_connections": false},
		m{"type": "direct", "tag": "vpn-direct"})
	// Журнал sing-box VPN — только предупреждения: в info попадают адреса сайтов.
	return json.Marshal(m{"log": m{"level": "warn"}, "inbounds": []m{tun}, "outbounds": outs, "route": route,
		"experimental": m{"clash_api": m{"external_controller": fmt.Sprintf("127.0.0.1:%d", rc.ClashPort), "secret": rc.ClashSecret}}})
}

// vpnGeoIP: нет поля — включено; явно пусто/ложь — выключено (_geoip_cfg v2).
func vpnGeoIP(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return true
	}
	var v any
	_ = json.Unmarshal(raw, &v)
	switch v := v.(type) {
	case nil:
		return false
	case bool:
		return v
	case float64:
		return v != 0
	case string:
		return v != ""
	case []any:
		return len(v) != 0
	case map[string]any:
		return len(v) != 0
	}
	return true
}

// vpnIDNA — lower/strip и punycode меток (RFC 3492), как _idna в vpn.py.
func vpnIDNA(domain string) string {
	labels := strings.Split(strings.Trim(strings.ToLower(strings.TrimSpace(domain)), "."), ".")
	for i, label := range labels {
		runes := []rune(label)
		var out strings.Builder
		for _, r := range runes {
			if r < 128 {
				out.WriteRune(r)
			}
		}
		basic := out.Len()
		if basic == len(runes) {
			continue
		}
		if basic > 0 {
			out.WriteByte('-')
		}
		n, delta, bias := 128, 0, 72
		for h := basic; h < len(runes); {
			m := 0x110000
			for _, r := range runes {
				if int(r) >= n && int(r) < m {
					m = int(r)
				}
			}
			delta += (m - n) * (h + 1)
			n = m
			for _, r := range runes {
				if int(r) < n {
					delta++
				}
				if int(r) != n {
					continue
				}
				q := delta
				for k := 36; ; k += 36 {
					t := max(1, min(26, k-bias))
					if q < t {
						break
					}
					out.WriteByte("abcdefghijklmnopqrstuvwxyz0123456789"[t+(q-t)%(36-t)])
					q = (q - t) / (36 - t)
				}
				out.WriteByte("abcdefghijklmnopqrstuvwxyz0123456789"[q])
				d := delta
				if h == basic {
					d /= 700
				} else {
					d /= 2
				}
				d += d / (h + 1)
				k := 0
				for d > 455 {
					d /= 35
					k += 36
				}
				bias = k + 36*d/(d+38)
				delta = 0
				h++
			}
			delta++
			n++
		}
		labels[i] = "xn--" + out.String()
	}
	return strings.Join(labels, ".")
}
