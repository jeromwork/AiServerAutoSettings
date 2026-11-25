package singbox

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/bus"
	"remoteagents/internal/cleanup"
	"remoteagents/internal/forward"
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
func renderVPNOnly(rc api.RenderContext, paths []api.VPNPath, probeURL string) ([]byte, error) {
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

// RenderVPN объединяет VPN и LAN в единственный процесс с правами.
// Конфиг без VPN тоже допустим: TUN ЛВС идёт в sing-box №1 через tun-lan.
func RenderVPN(rc api.RenderContext, paths []api.VPNPath, probeURL string) ([]byte, error) {
	lan, err := RenderLAN(rc)
	if err != nil {
		return nil, err
	}
	data, err := renderVPNOnly(rc, paths, probeURL)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 && len(lan.Inbounds) == 0 {
		return nil, nil
	}
	conf := map[string]any{"log": map[string]any{"level": "info"}, "inbounds": []map[string]any{}, "outbounds": []map[string]any{{"type": "direct", "tag": "direct"}}, "route": map[string]any{"rules": []map[string]any{}, "final": "direct", "auto_detect_interface": true}}
	// Typed slices keep the merge small and the order explicit.
	if len(data) > 0 {
		var old struct {
			Inbounds, Outbounds []map[string]any
			Route               map[string]any
		}
		if err := json.Unmarshal(data, &old); err != nil {
			return nil, err
		}
		var routeRules []map[string]any
		raw, _ := json.Marshal(old.Route["rules"])
		_ = json.Unmarshal(raw, &routeRules)
		old.Route["rules"] = routeRules
		conf["inbounds"], conf["outbounds"], conf["route"] = old.Inbounds, old.Outbounds, old.Route
	}
	conf["inbounds"] = append(lan.Inbounds, conf["inbounds"].([]map[string]any)...)
	conf["outbounds"] = append(conf["outbounds"].([]map[string]any), lan.Outbounds...)
	route := conf["route"].(map[string]any)
	route["rules"] = append(lan.Rules, route["rules"].([]map[string]any)...)
	if len(lan.Inbounds) > 0 {
		if _, _, err := addLANDNS(conf, rc); err != nil {
			return nil, err
		}
	}
	conf["experimental"] = map[string]any{"clash_api": map[string]any{"external_controller": net.JoinHostPort("127.0.0.1", strconv.Itoa(rc.ClashPort)), "secret": rc.ClashSecret}}
	return json.Marshal(conf)
}

// ApplyVPN: начальное применение и подписки на последующие события. Вызов не требует прав;
// только vpnrun запускает привилегированный sing-box и команды DNS.
func ApplyVPN(ctx context.Context, rc api.RenderContext, paths []api.VPNPath, foreign string, r *vpnrun.Runner) error {
	return r.Configure(func() error {
		desired := rc
		r.OnChange(func(ctx context.Context, ev bus.Event) error {
			return r.Configure(func() error {
				if ev.Topic == "settings.loaded" {
					if cfg, ok := ev.Data["config"].(*api.Config); ok {
						desired.Cfg = cfg
						candidates, _ := BuildPaths(cfg, desired.ProxyPorts, desired.VPNInterface)
						paths = nil
						for _, p := range candidates {
							via := ""
							if strings.HasSuffix(p.Name, "-vpn") {
								via = "vpn"
							}
							paths = append(paths, api.VPNPath{Name: p.Name, Kind: p.Kind, Via: via, Final: p.Final, Outs: p.Outbounds})
						}
					}
				}
				if !r.AllowEvent(ev.Topic) {
					return nil
				}
				active := desired
				if ev.Topic == "channel.down" {
					active.LANSocks = ""
				}
				return applyVPN(ctx, active, paths, foreign, r, false)
			})
		})
		return applyVPN(ctx, rc, paths, foreign, r, true)
	})
}

func applyVPN(ctx context.Context, rc api.RenderContext, paths []api.VPNPath, foreign string, r *vpnrun.Runner, manual bool) error {
	mode := VPNMode(rc.Cfg)
	geoChanged := false
	if !rc.Mode.AllowsTun() || rc.Cfg == nil {
		return r.Stop()
	}
	conflict := mode == "only" && foreign != ""
	if foreign != "" {
		copyCfg := *rc.Cfg
		copyCfg.VPN.Mode = "off"
		rc.Cfg = &copyCfg
	}
	if lanWanted(rc) && rc.LANSocks != "" {
		var err error
		rc.LANRoutes, err = forward.LANRoutes(ctx, rc.Cfg)
		if err != nil {
			return err
		}
	}
	if VPNMode(rc.Cfg) != "off" {
		if rc.GeoIPPath == "" {
			rc.GeoIPPath = filepath.Join(filepath.Dir(filepath.Dir(r.Conf)), "state", "vpn-geoip-ru.srs")
		}
		before, _ := os.Stat(rc.GeoIPPath)
		if err := fetchGeoIP(ctx, rc); err != nil && r.Log != nil {
			r.Log.Warn("vpn.geoip.failed", "err", err.Error())
		}
		if after, e := os.Stat(rc.GeoIPPath); e == nil {
			geoChanged = before == nil || !after.ModTime().Equal(before.ModTime())
		}
	}
	if rc.ClashPort == 0 && r.API != "" {
		_, p, _ := net.SplitHostPort(r.API)
		rc.ClashPort, _ = strconv.Atoi(p)
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
		rc.ClashSecret = r.Secret
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
	if len(data) == 0 {
		return r.Stop()
	}
	previous, _ := os.ReadFile(r.Conf)
	if r.Running() && bytes.Equal(previous, data) && !geoChanged {
		if conflict {
			return fmt.Errorf("работает другой VPN (%s) — отключите его, чтобы работал наш", foreign)
		}
		return nil
	}
	if err := r.Stop(); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(r.Conf), 0700); err != nil {
		return err
	}
	if err := os.WriteFile(r.Conf, data, 0600); err != nil {
		return err
	}
	checkCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if err := exec.CommandContext(checkCtx, r.Sing, "check", "-c", r.Conf).Run(); err != nil {
		return fmt.Errorf("VPN/LAN: конфиг не прошёл sing-box check: %w", err)
	}
	r.API, r.Secret = net.JoinHostPort("127.0.0.1", strconv.Itoa(rc.ClashPort)), rc.ClashSecret
	var exitTags []string
	lanOnly := VPNMode(rc.Cfg) == "off"
	if !lanOnly {
		for _, p := range vpnBridges(rc.Cfg, paths) {
			for _, o := range p.Outs {
				if tag, ok := o["tag"].(string); ok {
					exitTags = append(exitTags, tag)
				}
			}
		}
	}
	r.SetExits(exitTags, lanOnly)
	if lanWanted(rc) && rc.LANSocks != "" {
		for _, p := range lanDNS(rc.Cfg) {
			if len(p.Servers) == 0 {
				r.Bus.Publish("lan.dns.failed", map[string]any{"error": "share.dnsServers missing", "domains": p.Domains})
			}
		}
	}
	// Из готового конфига берём только реально включённый DNS, без догадок по флагам.
	var conf map[string]any
	_ = json.Unmarshal(data, &conf)
	var domains []string
	address := ""
	if conf["dns"] != nil {
		plans := rc.LANDNS
		if plans == nil {
			plans = lanDNS(rc.Cfg)
		}
		for _, p := range plans {
			if len(p.Servers) > 0 {
				domains = append(domains, p.Domains...)
			}
		}
		addr := rc.Cfg.Tun.Address
		if addr == "" {
			addr = "172.19.0.1/30"
		}
		ip, _, _ := net.ParseCIDR(addr)
		address = ip.String()
	}
	r.SetLAN(address, domains)
	if err := ctx.Err(); err != nil {
		return err
	}
	if manual {
		err = r.Start()
	} else {
		err = r.Resume()
	}
	if err == nil && conflict {
		return fmt.Errorf("работает другой VPN (%s) — отключите его, чтобы работал наш", foreign)
	}
	return err
}

// Проверка возраста только при старте и событиях сети; скачивание — одно действие до 30 с.
func fetchGeoIP(ctx context.Context, rc api.RenderContext) error {
	raw := rc.Cfg.VPN.Direct.GeoIP
	if !vpnGeoIP(raw) {
		return nil
	}
	cfg := struct {
		URL  string `json:"url"`
		Days any    `json:"refreshDays"`
	}{URL: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs", Days: 7}
	_ = json.Unmarshal(raw, &cfg)
	if cfg.URL == "" {
		cfg.URL = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"
	}
	days := 7
	if n, err := strconv.ParseFloat(fmt.Sprint(cfg.Days), 64); err == nil && n != 0 {
		days = max(1, int(n))
	}
	if st, err := os.Stat(rc.GeoIPPath); err == nil && time.Since(st.ModTime()) <= time.Duration(days)*24*time.Hour {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", cfg.URL, nil)
	if err != nil {
		return fmt.Errorf("invalid geoip URL")
	}
	client := &http.Client{Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true}}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("download failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("geoip HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return fmt.Errorf("read failed")
	}
	if !bytes.HasPrefix(data, []byte("SRS")) {
		return fmt.Errorf("not a rule-set")
	}
	if err := os.MkdirAll(filepath.Dir(rc.GeoIPPath), 0700); err != nil {
		return err
	}
	tmp := rc.GeoIPPath + ".tmp"
	defer os.Remove(tmp)
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, rc.GeoIPPath)
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
