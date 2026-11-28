package singbox

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
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
var vpnDirectProcs = append(ownProcNames(),
	"ra-lab.exe", "ra-lab", "ralab-core.exe", "ralab-core", "ralab.exe", "sing-box.exe", "sing-box",
	"Happ.exe", "happ.exe", "xray.exe", "v2rayN.exe", "tailscaled.exe", "Tailscale.exe",
)

// MaxVPNSplit — предел нарезки: 2^12 = 4096 блоков IPv4. /16 (65536 маршрутов) ОС добавляла бы минутами и сама стала бы помехой.
const MaxVPNSplit = 12

// SplitRoutes — route_address VPN. n<=1 — как раньше (0/1, 128/1, ::/1, 8000::/1); иначе 0.0.0.0/0 нарезан блоками /n
// (мельче маршрутов чужого VPN длиной n-1), IPv6 — глобальная 2000::/3 блоками /max(n,3).
func SplitRoutes(n int) []string {
	if n <= 1 {
		return []string{"0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"}
	}
	n = min(n, MaxVPNSplit)
	out := make([]string, 0, 1<<n+1<<(n-3+1))
	step := uint32(1) << (32 - n)
	for i := uint32(0); i < 1<<n; i++ {
		a := i * step
		out = append(out, fmt.Sprintf("%d.%d.%d.%d/%d", a>>24, a>>16&255, a>>8&255, a&255, n))
	}
	n6 := max(n, 3)
	for i := uint32(0); i < 1<<(n6-3); i++ {
		// 2000::/3 → первые n6 бит: 001 + (n6-3) бит счётчика; n6 <= 12, значит всё помещается в первые 16 бит
		hi := uint32(0x2000)>>(16-n6)<<(16-n6) | i<<(16-n6)
		out = append(out, fmt.Sprintf("%x::/%d", hi, n6))
	}
	return out
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

// VPNServerAddr — "ip:443" первого узла vpn.nodes (по имени), чей адрес разрешился; "" — узлов нет/не резолвятся.
// По нему определяется «нижний» адаптер (platform.UnderlayInterface): адрес исключён из нашего TUN.
func VPNServerAddr(cfg *api.Config) string {
	if cfg == nil {
		return ""
	}
	names := make([]string, 0, len(cfg.VPN.Nodes))
	for n := range cfg.VPN.Nodes {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		o, err := decodeObj(cfg.VPN.Nodes[n])
		if err != nil {
			continue
		}
		h, _ := o["server"].(string)
		for _, a := range resolveHost(h) {
			if ip, err := netip.ParseAddr(a); err == nil && ip.Is4() {
				return net.JoinHostPort(a, "443")
			}
		}
	}
	// Узлов нет: адрес сервера из путей канала (входные узлы по порядку, затем сам сервер) — по реальному маршруту ОС к нему
	// определяется, через какой интерфейс (при Happ — happ-tun) мы выходим.
	for _, h := range channelHosts(cfg) {
		for _, a := range resolveHost(h) {
			if ip, err := netip.ParseAddr(a); err == nil && ip.Is4() {
				return net.JoinHostPort(a, "443")
			}
		}
	}
	return ""
}

// channelHosts — хосты путей канала (узел каждого пути, порядок путей), затем хост сервера; без повторов.
func channelHosts(cfg *api.Config) []string {
	if cfg == nil || !cfg.HasChannel() {
		return nil
	}
	var out []string
	seen := map[string]bool{}
	add := func(h string) {
		if h != "" && !seen[h] {
			seen[h] = true
			out = append(out, h)
		}
	}
	if paths, _, err := buildPaths(cfg, cfg.Servers[0].Host); err == nil {
		for _, p := range paths {
			add(p.node)
		}
	}
	add(cfg.Servers[0].Host)
	return out
}

// vpnSel — мосты VPN: outbounds процесса, теги для urltest и хосты, которые не должны идти в наш TUN.
type vpnSel struct {
	outs   []m
	finals []string
	hosts  []string
}

// vpnSelect — мосты из vpn.nodes (узлы целиком) и из путей paths (если есть сервер) по vpn.bridges (пусто — все),
// без ssh/direct/socks и без путей «через чужой VPN». Узел с тем же именем, что и путь, главнее.
func vpnSelect(cfg *api.Config) (vpnSel, error) { return vpnSelectOpt(cfg, false, nil) }

// vpnSelectOpt — vpnSelect с учётом чужого VPN: тип моста не отсекается (под Happ на ПК владельца UDP-мосты hy2/tuic проходят,
// TCP — нет; решает замер, а не тип; foreign оставлен для сигнатуры); rank — пути канала, прошедшие свежий замер
// (победитель первым): остальные пути отбрасываются, если остался хоть один пригодный (иначе порядок конфига).
func vpnSelectOpt(cfg *api.Config, foreign bool, rank []string) (vpnSel, error) {
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
	ranked := map[string]int{}
	for i, n := range rank {
		if _, ok := ranked[n]; !ok {
			ranked[n] = i
		}
	}
	nodeFinals := len(sel.finals)
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
		// Свежий замер/гонка канала: только прошедшие, победитель первым; прошедших нет — порядок конфига.
		var pass []string
		for _, f := range sel.finals[nodeFinals:] {
			if _, ok := ranked[f]; ok {
				pass = append(pass, f)
			}
		}
		if len(pass) > 0 {
			sort.SliceStable(pass, func(i, j int) bool { return ranked[pass[i]] < ranked[pass[j]] })
			sel.finals = append(sel.finals[:nodeFinals:nodeFinals], pass...)
		}
	}
	// Рядом с чужим VPN мосты через CDN-домен исключаются: домен резолвится мимо чужого VPN в чужой адрес (сертификат не сходится).
	if foreign {
		var keep []string
		for _, f := range sel.finals {
			if !strings.HasPrefix(f, "ws-cdn-") && !strings.HasPrefix(f, "cdn-") {
				keep = append(keep, f)
			}
		}
		if len(keep) > 0 {
			sel.finals = keep
		}
	}
	// Серверы ВСЕХ выбранных мостов (в т.ч. путей канала) и сервер канала не должны идти в наш TUN: иначе после его подъёма
	// маршрут ОС к ним ведёт в наш адаптер и «нижний» адаптер (vpnUnderlay) ошибочно становится физическим.
	for _, o := range sel.outs {
		if s, _ := o["server"].(string); s != "" && s != "127.0.0.1" && s != "localhost" {
			hosts[s] = true
		}
	}
	if cfg.HasChannel() {
		hosts[cfg.Servers[0].Host] = true
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
	sel, err := vpnSelectOpt(rc.Cfg, rc.ForeignVPN, rc.PathRank)
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
	lock := rc.Cfg.VPN.LockExit // «выход только через наш адрес»: никаких прямых исключений (РФ, домены), strict_route
	var suffixes []string
	for _, d := range rc.Cfg.VPN.Direct.Domains {
		if !lock && strings.Trim(d, ". ") != "" {
			suffixes = append(suffixes, vpnIDNA(d))
		}
	}
	if len(suffixes) > 0 {
		rules = append(rules, m{"domain_suffix": suffixes, "outbound": "vpn-direct"})
	}
	route := m{"find_process": true, "final": "vpn-out"}
	switch {
	case rc.DefaultIface != "":
		// Под чужим VPN (Happ) rc.DefaultIface — физический интерфейс (замер на ПК: привязка к нему даёт все мосты за <1 с,
		// привязка к happ-tun и по маршрутам ОС — только часть). Петли нет: серверы мостов исключены из нашего TUN.
		route["default_interface"] = rc.DefaultIface
	default:
		route["auto_detect_interface"] = true
	}
	if !lock && rc.GeoIPPath != "" && vpnGeoIP(rc.Cfg.VPN.Direct.GeoIP) {
		if st, err := os.Stat(rc.GeoIPPath); err == nil && st.Mode().IsRegular() {
			rules = append(rules, m{"rule_set": []string{"geoip-ru"}, "outbound": "vpn-direct"})
			route["rule_set"] = []m{{"type": "local", "tag": "geoip-ru", "format": "binary", "path": rc.GeoIPPath}}
		}
	}
	if lock && rc.VPNBlock {
		// Перекрыто: свой процесс программы ходит через vpn-out (проверка «вышли ли мы через наш адрес» — это и есть выход из перекрытия),
		// остальное отклоняется. Исключения выше (приватные сети, процессы канала/Лаборатории) остаются: канал и страница 127.0.0.1 живы.
		if self := selfProcName(); self != "" {
			rules = append(rules, m{"process_name": []string{self}, "outbound": "vpn-out"})
		}
		rules = append(rules, m{"inbound": []string{"vpn-in"}, "action": "reject"})
	}
	route["rules"] = rules
	tun := m{"type": "tun", "tag": "vpn-in", "interface_name": name,
		"address": []string{"172.19.8.1/30", "fdfe:dcba:9877::1/126"}, "mtu": 1400,
		"auto_route": true, "strict_route": lock && !rc.ForeignVPN, // рядом с чужим TUN (Happ) strict_route/WFP вешает открытие адаптера
		"route_address":         SplitRoutes(rc.VPNSplit),
		"route_exclude_address": excludeSet(rc, sel.hosts)}
	if lock && vpnGOOS == "linux" {
		// Linux: sing-box сам ставит таблицу nftables и ip rule и снимает их при выходе; остатки после kill убирает platform.SweepVPNLock.
		tun["auto_redirect"] = true
	}
	outs := append([]m(nil), sel.outs...)
	direct := m{"type": "direct", "tag": "vpn-direct"}
	if rc.ForeignVPN && rc.DefaultIface != "" {
		// Без привязки vpn-direct ушёл бы по маршрутам ОС в наш TUN (0/1) — петля; привязываем к физическому интерфейсу.
		direct["bind_interface"] = rc.DefaultIface
	}
	outs = append(outs,
		m{"type": "urltest", "tag": "vpn-out", "outbounds": sel.finals, "url": VPNProbeURL, "interval": vpnTestInterval(rc.ForeignVPN), "timeout": "5s", "tolerance": 100, "interrupt_exist_connections": false},
		direct)
	// Журнал sing-box VPN — только предупреждения: в info попадают адреса сайтов. Под чужим VPN для разбора — info в файл.
	logCfg := m{"level": "warn"}
	if rc.ForeignVPN && rc.LogFile != "" {
		logCfg = m{"level": "debug", "output": rc.LogFile, "timestamp": true}
	}
	return json.Marshal(m{"log": logCfg, "inbounds": []m{tun}, "outbounds": outs, "route": route,
		"experimental": m{"clash_api": m{"external_controller": fmt.Sprintf("127.0.0.1:%d", rc.ClashPort), "secret": rc.ClashSecret}}})
}

// vpnTestInterval — период urltest: рядом с чужим VPN чаще, чтобы результат был быстро и после смены сети.
func vpnTestInterval(foreign bool) string {
	if foreign {
		return "1m"
	}
	return "3m"
}

// vpnGOOS — ОС для выбора способа перекрытия (подменяется в тестах).
var vpnGOOS = runtime.GOOS

// selfProcName — имя исполняемого файла этой программы (для правила process_name).
func selfProcName() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Base(exe)
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
