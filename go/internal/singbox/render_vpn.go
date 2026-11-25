package singbox

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/cleanup"
	"remoteagents/internal/vpnrun"
)

var vpnRUDomains = []string{
	"ru", "su", "xn--p1ai", "xn--p1acf", "xn--80adxhks", "xn--d1acj3b", "xn--80asehdb", "xn--80aswg", "xn--c1avg",
	"yandex.net", "yandex.com", "yastatic.net", "yandexcloud.net", "ya.cc", "vk.com", "vk.me", "vkuser.net", "userapi.com",
	"vk-cdn.net", "mycdn.me", "okcdn.ru", "mail.ru", "avito.st", "wbstatic.net", "wbbasket.ru", "ozone.ru", "tbank-online.com",
}

var vpnExclude = []string{
	"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "127.0.0.0/8", "224.0.0.0/4",
	"255.255.255.255/32", "1.1.1.1/32", "fc00::/7", "fe80::/10", "ff00::/8",
}

// VPNMode читает режим из конфига. Raw сохраняет различие между vpn:{} и отсутствующим vpn.
func VPNMode(cfg *api.Config) string {
	if cfg == nil {
		return "off"
	}
	var raw map[string]json.RawMessage
	if json.Unmarshal(cfg.Raw, &raw) != nil || len(raw["vpn"]) == 0 || strings.TrimSpace(string(raw["vpn"])) == "null" {
		return "off"
	}
	if cfg.VPN.Mode == "auto" || cfg.VPN.Mode == "only" {
		return cfg.VPN.Mode
	}
	return "off"
}

func vpnBridges(cfg *api.Config, paths []api.VPNPath) []api.VPNPath {
	var bridges []api.VPNPath
	for _, p := range paths {
		if p.Via != "" || p.Kind == "proxy" || p.Kind == "ssh" {
			continue
		}
		ok := len(cfg.VPN.Bridges) == 0
		for _, name := range cfg.VPN.Bridges {
			ok = ok || name == p.Name
		}
		for _, o := range p.Outs {
			if o["type"] == "ssh" || o["type"] == "direct" {
				ok = false
			}
		}
		if ok {
			bridges = append(bridges, p)
		}
	}
	return bridges
}

// RenderVPN строит отдельный конфиг vpn.py, не часть конфига канала/ЛВС.
// ExcludeIPs — уже разрешённые IP сервера, мостов и DNS ПК (или CIDR).
func RenderVPN(rc api.RenderContext, paths []api.VPNPath, probeURL string) ([]byte, error) {
	if VPNMode(rc.Cfg) == "off" || !rc.Mode.AllowsTun() {
		return nil, nil
	}
	bridges := vpnBridges(rc.Cfg, paths)
	if len(bridges) == 0 {
		return nil, fmt.Errorf("VPN: нет мостов без SSH и чужого VPN")
	}
	var outs []map[string]any
	var finals []string
	seen := map[string]bool{}
	for _, p := range bridges {
		finals = append(finals, p.Final)
		for _, src := range p.Outs {
			tag, _ := src["tag"].(string)
			if seen[tag] {
				continue
			}
			seen[tag] = true
			o := make(map[string]any, len(src))
			for k, v := range src {
				o[k] = v
			}
			switch o["type"] {
			case "vless", "trojan", "shadowtls", "ssh", "vmess", "shadowsocks", "direct":
				if o["detour"] == nil || o["detour"] == "" {
					o["tcp_keep_alive"], o["tcp_keep_alive_interval"] = "15s", "5s"
				}
			}
			outs = append(outs, o)
		}
	}
	if probeURL == "" {
		probeURL = vpnrun.DefaultProbeURL
	}
	probe, err := url.Parse(probeURL)
	if err != nil || probe.Hostname() == "" {
		return nil, fmt.Errorf("VPN: неверный адрес проверки туннеля")
	}
	probeRule := map[string]any{"domain": []string{probe.Hostname()}, "outbound": "vpn-out"}
	if ip, err := netip.ParseAddr(probe.Hostname()); err == nil {
		probeRule = map[string]any{"ip_cidr": []string{netip.PrefixFrom(ip, ip.BitLen()).String()}, "outbound": "vpn-out"}
	}
	rules := []map[string]any{{"action": "sniff"}, probeRule, {"ip_is_private": true, "outbound": "direct"}}
	domains := rc.Cfg.VPN.Direct.Domains
	if domains == nil {
		domains = vpnRUDomains
	}
	var suffixes []string
	for _, d := range domains {
		if strings.Trim(d, ".") != "" {
			suffixes = append(suffixes, vpnIDNA(d))
		}
	}
	if len(suffixes) != 0 {
		rules = append(rules, map[string]any{"domain_suffix": suffixes, "outbound": "direct"})
	}
	route := map[string]any{"rules": rules, "final": "vpn-out", "auto_detect_interface": true}
	if rc.GeoIPPath != "" && vpnGeoIP(rc.Cfg.VPN.Direct.GeoIP) {
		if st, err := os.Stat(rc.GeoIPPath); err == nil && st.Mode().IsRegular() {
			rules = append(rules, map[string]any{"rule_set": []string{"geoip-ru"}, "outbound": "direct"})
			route["rules"] = rules
			route["rule_set"] = []map[string]any{{"type": "local", "tag": "geoip-ru", "format": "binary", "path": rc.GeoIPPath}}
		}
	}
	excludes := append([]string(nil), vpnExclude...)
	seen = map[string]bool{}
	for _, v := range excludes {
		seen[v] = true
	}
	for _, v := range rc.ExcludeIPs {
		if ip, err := netip.ParseAddr(v); err == nil {
			v = netip.PrefixFrom(ip.WithZone(""), ip.BitLen()).String()
		}
		if !seen[v] {
			seen[v] = true
			excludes = append(excludes, v)
		}
	}
	tun := map[string]any{"type": "tun", "tag": "vpn-in", "interface_name": cleanup.VPNIface,
		"address": []string{"172.19.8.1/30", "fdfe:dcba:9877::1/126"}, "mtu": 1400,
		"auto_route": true, "strict_route": false, "stack": "mixed", "dns_mode": "disabled",
		"route_address": []string{"0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"}, "route_exclude_address": excludes}
	// §5б исключение: встроенный urltest sing-box выбирает мост раз в 3 минуты, как v2;
	// события доступности неиспользуемых мостов у sing-box нет. Сторож туннеля — событийный vpnrun.
	outs = append(outs, map[string]any{"type": "urltest", "tag": "vpn-out", "outbounds": finals,
		"url": "https://www.gstatic.com/generate_204", "interval": "3m", "tolerance": 100, "interrupt_exist_connections": false},
		map[string]any{"type": "direct", "tag": "direct"})
	return json.Marshal(map[string]any{"log": map[string]any{"level": "info"}, "inbounds": []map[string]any{tun},
		"outbounds": outs, "route": route, "experimental": map[string]any{"clash_api": map[string]any{
			"external_controller": net.JoinHostPort("127.0.0.1", strconv.Itoa(rc.ClashPort)), "secret": rc.ClashSecret}}})
}

// Отсутствующий geoip включает стандартный список; явно пустое/ложное значение выключает, как _geoip_cfg v2.
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

// ApplyVPN вызывается при настройках/смене сети. Бинарник в r.Sing уже подготовлен установщиком.
// auto уступает чужому VPN; only сообщает, что его надо отключить. Без vpn ничего не создаём и не запускаем.
func ApplyVPN(ctx context.Context, rc api.RenderContext, paths []api.VPNPath, foreign string, r *vpnrun.Runner) error {
	mode := VPNMode(rc.Cfg)
	if mode == "off" || !rc.Mode.AllowsTun() || foreign != "" {
		if err := r.Stop(); err != nil {
			return err
		}
		if mode == "only" && foreign != "" && rc.Mode.AllowsTun() {
			return fmt.Errorf("работает другой VPN (%s) — отключите его, чтобы работал наш", foreign)
		}
		return nil
	}
	if r.Running() {
		return nil // v2 _step: уже работающий VPN не перезапускается на каждое событие.
	}
	if len(vpnBridges(rc.Cfg, paths)) == 0 {
		return fmt.Errorf("VPN: нет мостов без SSH и чужого VPN")
	}
	if rc.ClashPort == 0 {
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return err
		}
		rc.ClashPort = l.Addr().(*net.TCPAddr).Port
		l.Close()
	}
	if rc.ClashSecret == "" {
		var secret [24]byte
		if _, err := rand.Read(secret[:]); err != nil {
			return err
		}
		rc.ClashSecret = base64.RawURLEncoding.EncodeToString(secret[:])
	}
	if r.Log != nil {
		r.Log.Secret(rc.ClashSecret)
	}
	data, err := RenderVPN(rc, paths, r.ProbeURL)
	if err != nil {
		return err
	}
	if err := r.Stop(); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(r.Conf), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(r.Conf, data, 0o600); err != nil {
		return err
	}
	checkCtx, cancel := context.WithTimeout(ctx, 15*time.Second) // v2: предел одного sing-box check — 15 с.
	defer cancel()
	if err := exec.CommandContext(checkCtx, r.Sing, "check", "-c", r.Conf).Run(); err != nil {
		return fmt.Errorf("VPN: конфиг не прошёл sing-box check: %w", err)
	}
	r.API, r.Secret = net.JoinHostPort("127.0.0.1", strconv.Itoa(rc.ClashPort)), rc.ClashSecret
	// vpnrun ищет ошибки конкретного узла выхода, а не группы urltest.
	r.Exit = vpnBridges(rc.Cfg, paths)[0].Final
	if err := ctx.Err(); err != nil {
		return err
	}
	return r.Start()
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
