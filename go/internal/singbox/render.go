package singbox

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"

	"remoteagents/internal/api"
)

// Render повторяет lab/ralab/paths.py make_config (v2) после чистки V11: один вход in-chan -> selector chan
// -> outbounds путей, Clash API на 127.0.0.1. Части VPN/LAN (renderVPN/renderLAN) дописывают свои inbounds,
// outbounds и правила ПОСЛЕ правил канала.

type m = map[string]any

const maxPaths = 64

var (
	allKinds = []string{"hy2", "hy2obfs", "tuic", "trojan", "reality", "shadowtls", "ws-direct", "ws-cdn"}
	nameRE   = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$`)
	hopRE    = regexp.MustCompile(`^(?:([a-z_][a-z0-9_-]{0,31})@)?([a-zA-Z0-9][a-zA-Z0-9.-]{0,252})(?::(\d{1,5}))?$`)
	tcpTypes = map[string]bool{"vless": true, "trojan": true, "shadowtls": true, "ssh": true, "vmess": true, "shadowsocks": true, "direct": true}
	// localProxyPorts — SOCKS5/mixed других VPN (Happ/v2rayN 10808, Clash 7890/7891), paths.py LOCAL_PROXIES.
	localProxyPorts = []int{10808, 7890, 7891}
	// vpnIface — имя интерфейса чужого VPN (paths.py vpn_iface); "" — нет. Платформенная часть подставляет своё (в RenderContext платформы нет).
	vpnIface = func() string { return "" }
	// probeLocal — открыт ли порт 127.0.0.1 (петля отвечает сразу; таймаут — только предохранитель).
	probeLocal = func(port int) bool {
		c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), time.Second)
		if err != nil {
			return false
		}
		c.Close()
		return true
	}
)

type chanPath struct {
	name, final, node string
	outs              []m
}

func Render(rc api.RenderContext) ([]byte, error) {
	if rc.Cfg == nil || len(rc.Cfg.Servers) == 0 {
		return nil, errors.New("singbox: render: no server in config")
	}
	srv := rc.Cfg.Servers[0]
	if srv.Host == "" || srv.Port <= 0 {
		return nil, errors.New("singbox: render: invalid server")
	}
	if rc.ChanPort <= 0 || rc.ClashPort <= 0 {
		return nil, errors.New("singbox: render: ports are not set")
	}
	paths, _, err := buildPaths(rc.Cfg, srv.Host)
	if err != nil {
		return nil, err
	}
	var ins, rules, outs []m
	var names []string
	tags := map[string]bool{}
	seenName := map[string]bool{}
	for _, p := range paths {
		if p.name != "chan" && !seenName[p.name] { // имя chan занято тегом selector
			seenName[p.name] = true
			names = append(names, p.name)
		}
		for _, o := range p.outs {
			tag, _ := o["tag"].(string)
			if tags[tag] {
				continue
			}
			tags[tag] = true
			o = cloneM(o)
			if t, _ := o["type"].(string); tcpTypes[t] && o["detour"] == nil { // детектор заморозки: закрыть TCP через ~15 с + 9 x 5 с
				o["tcp_keep_alive"], o["tcp_keep_alive_interval"] = "15s", "5s"
			}
			outs = append(outs, o)
		}
	}
	if len(names) > 0 && !tags["chan"] {
		ins = append(ins, m{"type": "direct", "tag": "in-chan", "listen": "127.0.0.1", "listen_port": rc.ChanPort, "override_address": srv.Host, "override_port": srv.Port})
		outs = append(outs, m{"type": "selector", "tag": "chan", "outbounds": names, "default": names[0], "interrupt_exist_connections": false})
		rules = append(rules, m{"inbound": "in-chan", "outbound": "chan"})
	}
	route := m{"auto_detect_interface": true}
	var ruleSets []m
	if rc.Mode.AllowsTun() {
		type part struct {
			on bool
			f  func(api.RenderContext) (api.Part, error)
		}
		for _, pt := range []part{{rc.Effective.VPN, renderVPN}, {rc.Effective.LAN, renderLAN}} {
			if !pt.on {
				continue
			}
			x, err := pt.f(rc)
			if err != nil {
				return nil, err
			}
			ins, outs, rules, ruleSets = append(ins, x.Inbounds...), append(outs, x.Outbounds...), append(rules, x.Rules...), append(ruleSets, x.RuleSets...)
		}
	}
	route["rules"] = rules
	if len(ruleSets) > 0 {
		route["rule_set"] = ruleSets
	}
	return json.Marshal(m{"log": m{"level": "info"}, "inbounds": ins, "outbounds": outs, "route": route,
		"experimental": m{"clash_api": m{"external_controller": fmt.Sprintf("127.0.0.1:%d", rc.ClashPort), "secret": rc.ClashSecret}}})
}

// rd читает поля узла; первая нехватка запоминается (KeyError paths.py).
type rd struct{ err error }

func (r *rd) get(x m, k string) any {
	v, ok := x[k]
	if !ok || v == nil {
		if r.err == nil {
			r.err = fmt.Errorf("нет поля %s", k)
		}
		return ""
	}
	return v
}
func (r *rd) str(x m, k string) string { s, _ := r.get(x, k).(string); return s }
func (r *rd) obj(x m, k string) m {
	o, _ := r.get(x, k).(m)
	if o == nil {
		o = m{}
	}
	return o
}
func (r *rd) num(x m, k string) int {
	n, ok := toInt(r.get(x, k))
	if !ok && r.err == nil {
		r.err = fmt.Errorf("поле %s не число", k)
	}
	return n
}

func toInt(v any) (int, bool) {
	switch t := v.(type) {
	case float64:
		return int(t), true
	case int:
		return t, true
	case string:
		n, err := strconv.Atoi(strings.TrimSpace(t))
		return n, err == nil
	}
	return 0, false
}

func cloneM(x m) m {
	b, _ := json.Marshal(x)
	var o m
	_ = json.Unmarshal(b, &o)
	return o
}

func decodeObj(raw []byte) (m, error) {
	var o m
	if err := json.Unmarshal(raw, &o); err != nil || o == nil {
		return nil, errors.New("invalid JSON")
	}
	return o, nil
}

func merge(a m, b m) m {
	o := cloneM(a)
	for k, v := range b {
		o[k] = v
	}
	return o
}

func entryOutbounds(e m, name, server string) (map[string]struct {
	outs  []m
	final string
}, error) {
	r := &rd{}
	x, p := r.obj(e, "secrets"), r.obj(e, "ports")
	s := server
	if v, _ := e["server"].(string); v != "" {
		s = v
	}
	sni, cover := r.str(e, "sni"), r.str(e, "cover")
	insecure, _ := e["insecure"].(bool)
	tls := m{"enabled": true, "server_name": sni, "insecure": insecure}
	h3 := merge(tls, m{"alpn": []any{"h3"}})
	u := m{"enabled": true, "fingerprint": "chrome"}
	cv := m{"enabled": true, "server_name": cover, "utls": u}
	rs := map[string]m{
		"hy2":     {"type": "hysteria2", "server_port": r.num(p, "hy2"), "password": r.str(x, "hy2"), "tls": h3},
		"hy2obfs": {"type": "hysteria2", "server_port": r.num(p, "hy2_obfs"), "password": r.str(x, "hy2"), "tls": h3, "obfs": m{"type": "salamander", "password": r.str(x, "hy2_obfs")}},
		"tuic":    {"type": "tuic", "server_port": r.num(p, "tuic"), "uuid": r.str(x, "tuic_uuid"), "password": r.str(x, "tuic"), "congestion_control": "bbr", "tls": h3},
		"trojan":  {"type": "trojan", "server_port": r.num(p, "trojan"), "password": r.str(x, "trojan"), "tls": tls},
		"reality": {"type": "vless", "server_port": r.num(p, "reality"), "uuid": r.str(x, "vless_uuid"), "flow": "xtls-rprx-vision",
			"tls": merge(cv, m{"reality": m{"enabled": true, "public_key": r.str(x, "reality_public"), "short_id": r.str(x, "short_id")}})},
	}
	ssTag, stTag := "shadowtls-"+name, "stls-"+name
	st := m{"type": "shadowtls", "tag": stTag, "server": s, "server_port": r.num(p, "shadowtls"), "version": 3, "password": r.str(x, "shadowtls"), "tls": cv}
	ss := m{"type": "shadowsocks", "tag": ssTag, "method": "2022-blake3-aes-128-gcm", "password": r.str(x, "ss"), "detour": stTag}
	if wp, _ := x["ws_path"].(string); wp != "" {
		domain, _ := e["domain"].(string)
		wsv := func(srv, d string, insecure bool) m {
			tl := m{"enabled": true, "server_name": d, "alpn": []any{"http/1.1"}, "utls": u}
			if insecure {
				tl["insecure"] = true
			}
			return m{"type": "vless", "server": srv, "server_port": 443, "uuid": r.str(x, "ws_uuid"), "tls": tl, "transport": m{
				"type": "ws", "path": wp, "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol", "headers": m{"Host": d}}}
		}
		d := domain
		if d == "" {
			d = sni
		}
		rs["ws-direct"] = wsv(s, d, true)
		if domain != "" {
			rs["ws-cdn"] = wsv(domain, domain, false)
		}
	}
	if r.err != nil {
		return nil, r.err
	}
	out := map[string]struct {
		outs  []m
		final string
	}{}
	for k, o := range rs {
		o["tag"] = k + "-" + name
		if _, ok := o["server"]; !ok {
			o["server"] = s
		}
		out[k] = struct {
			outs  []m
			final string
		}{[]m{o}, k + "-" + name}
	}
	out["shadowtls"] = struct {
		outs  []m
		final string
	}{[]m{st, ss}, ssTag}
	return out, nil
}

func matchHostField(field, name string) bool {
	if strings.HasPrefix(field, "|1|") {
		parts := strings.Split(field, "|")
		if len(parts) != 4 {
			return false
		}
		salt, err1 := base64.StdEncoding.DecodeString(parts[2])
		want, err2 := base64.StdEncoding.DecodeString(parts[3])
		if err1 != nil || err2 != nil {
			return false
		}
		h := hmac.New(sha1.New, salt)
		h.Write([]byte(name))
		return hmac.Equal(h.Sum(nil), want)
	}
	hit := false
	for _, pat := range strings.Split(field, ",") {
		neg := strings.HasPrefix(pat, "!")
		pat = strings.TrimPrefix(pat, "!")
		if ok, _ := path.Match(pat, name); ok {
			if neg {
				return false
			}
			hit = true
		}
	}
	return hit
}

func knownHostKeys(file, host string, port int) []string {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil
	}
	name := host
	if port != 22 {
		name = "[" + host + "]:" + strconv.Itoa(port)
	}
	var keys []string
	for _, ln := range strings.Split(strings.TrimPrefix(string(data), "\uFEFF"), "\n") {
		f := strings.Fields(strings.TrimSpace(ln))
		if len(f) < 3 || strings.HasPrefix(f[0], "#") || strings.HasPrefix(f[0], "@") {
			continue
		}
		if matchHostField(f[0], name) {
			keys = append(keys, f[1]+" "+f[2])
		}
	}
	return keys
}

func hostKeyAlgs(keys []string) []any {
	var a []any
	for _, k := range keys {
		t := strings.Fields(k)[0]
		if t == "ssh-rsa" {
			a = append(a, "rsa-sha2-512", "rsa-sha2-256")
		} else {
			a = append(a, t)
		}
	}
	return a
}

func hopOutbound(hop m, name string) (m, error) {
	ssh, _ := hop["ssh"].(string)
	if ssh == "" {
		ssh, _ = hop["alias"].(string)
	}
	g := hopRE.FindStringSubmatch(ssh)
	if g == nil || g[1] == "" {
		return nil, errors.New("hop: нужен адрес вида логин@хост[:порт]")
	}
	port := 22
	if g[3] != "" {
		port, _ = strconv.Atoi(g[3])
	}
	key, _ := hop["keyFile"].(string)
	if st, err := os.Stat(key); port <= 0 || port > 65535 || key == "" || err != nil || st.IsDir() {
		return nil, errors.New("hop: неверный порт или нет keyFile")
	}
	var keys []string
	if kh, _ := hop["knownHostsPath"].(string); kh != "" {
		keys = knownHostKeys(kh, g[2], port)
	}
	if len(keys) == 0 {
		switch pin := hop["hostKey"].(type) {
		case string:
			keys = []string{pin}
		case []any:
			for _, k := range pin {
				if s, ok := k.(string); ok {
					keys = append(keys, s)
				}
			}
		}
	}
	if len(keys) == 0 {
		if h, err := os.UserHomeDir(); err == nil && hop["knownHostsPath"] == nil {
			keys = knownHostKeys(h+"/.ssh/known_hosts", g[2], port)
		}
	}
	if len(keys) == 0 {
		return nil, errors.New("нет закреплённого ключа хоста SSH-перехода")
	}
	o := m{"type": "ssh", "tag": "hop-" + name, "server": g[2], "server_port": port, "user": g[1], "private_key_path": key, "host_key": strs(keys)}
	if a := hostKeyAlgs(keys); len(a) > 0 {
		o["host_key_algorithms"] = a
	}
	return o, nil
}

func strs(s []string) []any {
	a := make([]any, len(s))
	for i, v := range s {
		a[i] = v
	}
	return a
}

func viaVPN(p chanPath, vpn string) chanPath {
	ren := map[string]string{}
	for _, o := range p.outs {
		t, _ := o["tag"].(string)
		ren[t] = t + "-vpn"
	}
	q := chanPath{name: ren[p.final], final: ren[p.final], node: p.node + " через " + vpn}
	for _, o := range p.outs {
		o = cloneM(o)
		o["tag"] = ren[o["tag"].(string)]
		if d, _ := o["detour"].(string); d != "" {
			if n, ok := ren[d]; ok {
				o["detour"] = n
			}
		} else {
			o["bind_interface"] = vpn
		}
		q.outs = append(q.outs, o)
	}
	return q
}

func itemName(it m) string {
	if n, _ := it["name"].(string); n != "" {
		return n
	}
	n, _ := it["entry"].(string)
	return n
}

// buildPaths — paths.py build_paths: ([путь], {что пропущено: причина}). Порядок: узлы входа, relay, hop, cdn, ssh-direct, vless-direct, ws, socks, via-vpn.
func buildPaths(cfg *api.Config, server string) ([]chanPath, map[string]string, error) {
	var vl m
	if len(cfg.Paths.Channel) > 0 {
		ch, err := decodeObj(cfg.Paths.Channel)
		if err != nil {
			return nil, nil, fmt.Errorf("singbox: render: paths.channel: %w", err)
		}
		obs, _ := ch["outbounds"].([]any)
		for _, o := range obs {
			if om, ok := o.(m); ok && om["type"] == "vless" {
				vl = om
				break
			}
		}
	}
	var paths []chanPath
	miss := map[string]string{}
	add := func(outs []m, final string) {
		node := server
		if v, _ := outs[0]["server"].(string); v != "" {
			node = v
		}
		paths = append(paths, chanPath{name: final, final: final, outs: outs, node: node})
	}
	vless := func(tag string, kw m) m {
		o := cloneM(vl)
		delete(o, "detour")
		o["tag"] = tag
		for k, v := range kw {
			o[k] = v
		}
		return o
	}
	entryFile := func(n string) (m, error) {
		raw, ok := cfg.Paths.Secrets[n]
		if !ok {
			return nil, errors.New("нет секрета узла")
		}
		return decodeObj(raw)
	}
	type item struct {
		kind string
		it   m
		ent  *api.EntryRef
	}
	var items []item
	for i := range cfg.Paths.Entries {
		e := &cfg.Paths.Entries[i]
		if e.Enabled {
			items = append(items, item{kind: "entry", it: m{"name": e.Name}, ent: e})
		}
	}
	for _, g := range []struct {
		k string
		l []m
	}{{"relay", cfg.Paths.Relays}, {"hop", cfg.Paths.Hops}, {"cdn", cfg.Paths.CDN}} {
		for _, it := range g.l {
			if en, ok := it["enabled"].(bool); ok && !en {
				continue
			}
			items = append(items, item{kind: g.k, it: it})
		}
	}
	for _, x := range items {
		n := itemName(x.it)
		fail := func(err error) { miss[x.kind+":"+n] = "пропущен: " + err.Error() }
		if n == "" || !nameRE.MatchString(n) {
			fail(errors.New("имя пути: только буквы, цифры, _ и -"))
			continue
		}
		switch x.kind {
		case "entry":
			e, err := entryFile(n)
			if err != nil {
				fail(err)
				continue
			}
			res, err := entryOutbounds(e, n, server)
			if err != nil {
				fail(err)
				continue
			}
			kinds := x.ent.Kinds
			if len(kinds) == 0 {
				kinds = allKinds
			}
			for _, k := range allKinds { // порядок как в entry_outbounds: hy2..reality, ws-direct, ws-cdn, shadowtls
				if k == "shadowtls" || !has(kinds, k) {
					continue
				}
				if v, ok := res[k]; ok {
					add(v.outs, v.final)
				}
			}
			if v, ok := res["shadowtls"]; ok && has(kinds, "shadowtls") {
				add(v.outs, v.final)
			}
		case "cdn":
			e, err := entryFile(n2(x.it, "entry"))
			if err != nil {
				fail(err)
				continue
			}
			r := &rd{}
			sec := r.obj(e, "secrets")
			d := r.str(x.it, "domain")
			wsPath, _ := x.it["path"].(string)
			if wp, _ := sec["ws_path"].(string); wsPath == "" {
				wsPath = wp
			}
			if sec["ws_uuid"] == nil || sec["ws_uuid"] == "" || sec["ws_path"] == nil || sec["ws_path"] == "" {
				fail(errors.New("узел не содержит WebSocket"))
				continue
			}
			uuid := r.str(sec, "ws_uuid")
			if r.err != nil {
				fail(r.err)
				continue
			}
			add([]m{{"type": "vless", "tag": "cdn-" + n, "server": d, "server_port": 443, "uuid": uuid,
				"tls":       m{"enabled": true, "server_name": d, "alpn": []any{"http/1.1"}, "utls": m{"enabled": true, "fingerprint": "chrome"}},
				"transport": m{"type": "ws", "path": wsPath, "headers": m{"Host": d}, "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol"}}}, "cdn-"+n)
		default:
			if vl == nil {
				fail(errors.New("в channel нет VLESS"))
				continue
			}
			if x.kind == "relay" {
				host, _ := x.it["host"].(string)
				if host == "" {
					host, _ = x.it["server"].(string)
				}
				port, ok := toInt(x.it["port"])
				if host == "" || !ok {
					fail(errors.New("нет host/port"))
					continue
				}
				tag := "vless-relay-" + n
				add([]m{vless(tag, m{"server": host, "server_port": port})}, tag)
			} else {
				h, err := hopOutbound(x.it, n)
				if err != nil {
					fail(err)
					continue
				}
				tag := "vless-sshhop-" + n
				add([]m{h, vless(tag, m{"detour": h["tag"], "server": server})}, tag)
			}
		}
	}
	// Прямой SSH к серверу: ТСПУ режет VLESS/HTTP к серверу, SSH:22 — нет.
	add([]m{{"type": "direct", "tag": "ssh-direct"}}, "ssh-direct")
	if vl != nil {
		add([]m{vless("vless-direct", m{"server": server})}, "vless-direct")
	}
	var ws []m
	for _, w := range cfg.Paths.WSEntries {
		r := &rd{}
		name := "ws-" + r.str(w, "name")
		if vl == nil {
			miss[name] = "пропущен: в channel нет VLESS (uuid)"
			continue
		}
		if !nameRE.MatchString(name) {
			miss[name] = "пропущен: имя пути: только буквы, цифры, _ и -"
			continue
		}
		host, path := r.str(w, "host"), r.str(w, "path")
		port := r.num(w, "port")
		if r.err != nil {
			miss[name] = "пропущен: " + r.err.Error()
			continue
		}
		tls := m{"enabled": true, "server_name": host, "alpn": []any{"http/1.1"}}
		if c, _ := w["certificate"].(string); c != "" {
			tls["certificate"] = c // самоподписанный сертификат сервера: доверяем только ему
		} else {
			tls["insecure"] = true
		}
		srv := host
		if a, _ := w["address"].(string); a != "" {
			srv = a
		}
		o := m{"type": "vless", "tag": name, "server": srv, "server_port": port, "uuid": vl["uuid"], "tls": tls,
			"transport": m{"type": "ws", "path": path, "headers": m{"Host": host}}}
		add([]m{o}, name)
		ws = append(ws, o)
	}
	var proxies []chanPath
	for _, port := range localProxyList() {
		so := m{"type": "socks", "tag": fmt.Sprintf("socks%d", port), "server": "127.0.0.1", "server_port": port, "version": "5"}
		node := fmt.Sprintf("127.0.0.1:%d", port)
		proxies = append(proxies, chanPath{name: so["tag"].(string), final: so["tag"].(string), outs: []m{so}, node: node})
		for _, o := range ws {
			tag := fmt.Sprintf("%s-socks%d", o["tag"], port)
			c := cloneM(o)
			c["tag"], c["detour"] = tag, so["tag"]
			proxies = append(proxies, chanPath{name: tag, final: tag, node: node, outs: []m{so, c}})
		}
		if vl != nil {
			tag := fmt.Sprintf("vless-socks%d", port)
			proxies = append(proxies, chanPath{name: tag, final: tag, node: node, outs: []m{so, vless(tag, m{"detour": so["tag"], "server": server})}})
		}
	}
	base := append([]chanPath(nil), paths...)
	paths = append(paths, proxies...)
	if v := vpnIface(); v != "" { // каждый путь ещё и через VPN: все пробуются одновременно
		for _, p := range base {
			paths = append(paths, viaVPN(p, v))
		}
	}
	seen := map[string]bool{}
	var res []chanPath
	for _, p := range paths {
		if !seen[p.name] {
			seen[p.name] = true
			res = append(res, p)
		}
	}
	if len(res) > maxPaths {
		res = res[:maxPaths]
	}
	return res, miss, nil
}

func localProxyList() []int {
	var found []int
	for _, p := range localProxyPorts {
		if probeLocal(p) {
			found = append(found, p)
		}
	}
	return found
}

func n2(x m, k string) string { s, _ := x[k].(string); return s }

func has(l []string, s string) bool {
	for _, v := range l {
		if v == s {
			return true
		}
	}
	return false
}
