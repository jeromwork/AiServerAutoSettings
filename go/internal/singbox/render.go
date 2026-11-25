// Rendering and transport candidates follow v2 paths.py.
package singbox

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"remoteagents/internal/api"
)

type object = map[string]any

var pathName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$`)
var hopName = regexp.MustCompile(`^([a-z_][a-z0-9_-]{0,31})@([a-zA-Z0-9][a-zA-Z0-9.-]{0,252})(?::([0-9]{1,5}))?$`)
var kinds = []string{"hy2", "hy2obfs", "tuic", "trojan", "reality", "shadowtls", "ws-direct", "ws-cdn"}

func str(v any) string {
	if v == nil {
		return ""
	}
	return fmt.Sprint(v)
}
func num(v any) int { n, _ := strconv.Atoi(str(v)); return n }
func obj(v any) object {
	m, _ := v.(map[string]any)
	if m == nil {
		return object{}
	}
	return m
}
func arr(v any) []any { a, _ := v.([]any); return a }
func fallback(v, d any) any {
	if v == nil || v == "" {
		return d
	}
	return v
}
func clone(m object) object {
	b, _ := json.Marshal(m)
	var n object
	_ = json.Unmarshal(b, &n)
	return n
}
func with(m object, kv ...any) object {
	n := clone(m)
	for i := 0; i < len(kv); i += 2 {
		n[kv[i].(string)] = kv[i+1]
	}
	return n
}
func contains(a []string, s string) bool {
	for _, x := range a {
		if x == s {
			return true
		}
	}
	return false
}

func checkEntry(e object) error {
	for _, key := range []string{"server", "sni", "cover", "ports", "secrets"} {
		if _, ok := e[key]; !ok {
			return fmt.Errorf("нет поля %s", key)
		}
	}
	for _, key := range []string{"hy2", "hy2_obfs", "tuic", "trojan", "reality", "shadowtls"} {
		if _, err := strconv.Atoi(str(obj(e["ports"])[key])); err != nil {
			return fmt.Errorf("неверный порт %s", key)
		}
	}
	x := obj(e["secrets"])
	for _, key := range []string{"hy2", "hy2_obfs", "tuic_uuid", "tuic", "trojan", "vless_uuid", "reality_public", "short_id", "shadowtls", "ss"} {
		if _, ok := x[key]; !ok {
			return fmt.Errorf("нет поля %s", key)
		}
	}
	if str(x["ws_path"]) != "" {
		if _, ok := x["ws_uuid"]; !ok {
			return errors.New("нет поля ws_uuid")
		}
	}
	return nil
}

func entryOutbounds(e object, name string) map[string][]object {
	x, p := obj(e["secrets"]), obj(e["ports"])
	s := e["server"]
	tls := object{"enabled": true, "server_name": e["sni"], "insecure": e["insecure"] == true}
	h3 := with(tls, "alpn", []string{"h3"})
	u := object{"enabled": true, "fingerprint": "chrome"}
	cover := object{"enabled": true, "server_name": e["cover"], "utls": u}
	r := map[string]object{
		"hy2":     {"type": "hysteria2", "server_port": p["hy2"], "password": x["hy2"], "tls": h3},
		"hy2obfs": {"type": "hysteria2", "server_port": p["hy2_obfs"], "password": x["hy2"], "tls": h3, "obfs": object{"type": "salamander", "password": x["hy2_obfs"]}},
		"tuic":    {"type": "tuic", "server_port": p["tuic"], "uuid": x["tuic_uuid"], "password": x["tuic"], "congestion_control": "bbr", "tls": h3},
		"trojan":  {"type": "trojan", "server_port": p["trojan"], "password": x["trojan"], "tls": tls},
		"reality": {"type": "vless", "server_port": p["reality"], "uuid": x["vless_uuid"], "flow": "xtls-rprx-vision", "tls": with(cover, "reality", object{"enabled": true, "public_key": x["reality_public"], "short_id": x["short_id"]})},
	}
	if str(x["ws_path"]) != "" {
		domain := fallback(e["domain"], e["sni"])
		r["ws-direct"] = wsOutbound(s, domain, 443, x["ws_uuid"], x["ws_path"], true, true)
		if str(e["domain"]) != "" {
			r["ws-cdn"] = wsOutbound(e["domain"], e["domain"], 443, x["ws_uuid"], x["ws_path"], false, true)
		}
	}
	out := map[string][]object{}
	for k, o := range r {
		out[k] = []object{with(o, "tag", k+"-"+name, "server", fallback(o["server"], s), "server_port", num(o["server_port"]))}
	}
	out["shadowtls"] = []object{
		{"type": "shadowtls", "tag": "stls-" + name, "server": s, "server_port": num(p["shadowtls"]), "version": 3, "password": x["shadowtls"], "tls": cover},
		{"type": "shadowsocks", "tag": "shadowtls-" + name, "method": "2022-blake3-aes-128-gcm", "password": x["ss"], "detour": "stls-" + name},
	}
	return out
}
func wsOutbound(server, domain any, port int, uuid, path any, insecure, early bool) object {
	tls := object{"enabled": true, "server_name": domain, "alpn": []string{"http/1.1"}}
	if insecure {
		tls["insecure"] = true
	}
	transport := object{"type": "ws", "path": path, "headers": object{"Host": domain}}
	if early {
		tls["utls"] = object{"enabled": true, "fingerprint": "chrome"}
		transport["max_early_data"] = 2048
		transport["early_data_header_name"] = "Sec-WebSocket-Protocol"
	}
	return object{"type": "vless", "server": server, "server_port": port, "uuid": uuid, "tls": tls, "transport": transport}
}

// BuildPaths consumes decrypted config only; it never opens a channel or secret file.
// ProxyPorts and VPNInterface are supplied by the platform on start/net.changed.
func BuildPaths(cfg *api.Config, proxyPorts []int, vpnInterface string) ([]api.ChannelPath, map[string]string) {
	paths := []api.ChannelPath{}
	miss := map[string]string{}
	if cfg == nil || len(cfg.Paths.Channel) == 0 {
		return paths, miss
	}
	var channel object
	if json.Unmarshal(cfg.Paths.Channel, &channel) != nil {
		miss["channel"] = "неверный JSON"
		return paths, miss
	}
	var vl object
	for _, o := range arr(channel["outbounds"]) {
		if obj(o)["type"] == "vless" {
			vl = clone(obj(o))
			delete(vl, "detour")
			break
		}
	}
	server := ""
	if len(cfg.Servers) > 0 {
		server = cfg.Servers[0].Host
	}
	add := func(kind string, outs []object, final string) {
		node := server
		if len(outs) > 0 && str(outs[0]["server"]) != "" {
			node = str(outs[0]["server"])
		}
		paths = append(paths, api.ChannelPath{Name: final, Kind: kind, Outbounds: outs, Final: final, Node: node})
	}
	entry := func(name string) (object, error) {
		var e object
		if json.Unmarshal(cfg.Paths.Secrets[name], &e) != nil || len(obj(e["secrets"])) == 0 {
			return nil, errors.New("нет секретов узла")
		}
		return e, nil
	}
	for _, it := range cfg.Paths.Entries {
		if !it.Enabled {
			continue
		}
		n := it.Name
		if !pathName.MatchString(n) {
			miss["entry:"+n] = "имя пути: только буквы, цифры, _ и -"
			continue
		}
		e, err := entry(n)
		if err != nil {
			miss["entry:"+n] = err.Error()
			continue
		}
		if err := checkEntry(e); err != nil {
			miss["entry:"+n] = err.Error()
			continue
		}
		candidates := entryOutbounds(e, n)
		selected := it.Kinds
		if len(selected) == 0 {
			selected = kinds
		}
		// Python inserts WebSocket variants before shadowtls.
		for _, k := range []string{"hy2", "hy2obfs", "tuic", "trojan", "reality", "ws-direct", "ws-cdn", "shadowtls"} {
			if outs := candidates[k]; len(outs) > 0 && contains(selected, k) {
				add("entry", outs, str(outs[len(outs)-1]["tag"]))
			}
		}
	}
	var raw object
	_ = json.Unmarshal(cfg.Raw, &raw)
	t := obj(raw["transport"])
	hops := append([]object(nil), cfg.Paths.Hops...)
	route := obj(t["serverRoute"])
	if len(route) == 0 {
		route = obj(obj(raw["wizard"])["serverRoute"])
	}
	if route["used"] == "hop" && len(obj(route["hop"])) > 0 {
		h := with(obj(route["hop"]), "name", "wizard-server-route", "enabled", true)
		prof := obj(raw["profile"])
		if str(h["knownHostsPath"]) == "" && str(prof["knownHostsPath"]) != "" {
			h["knownHostsPath"] = filepath.Join(filepath.Dir(str(prof["knownHostsPath"])), "known_hosts-hop")
		}
		filtered := []object{}
		for _, old := range hops {
			if old["name"] != "wizard-server-route" {
				filtered = append(filtered, old)
			}
		}
		hops = append(filtered, h)
	}
	for _, group := range []struct {
		kind  string
		items []object
	}{{"relay", cfg.Paths.Relays}, {"hop", hops}, {"cdn", cfg.Paths.CDN}} {
		for _, it := range group.items {
			if it["enabled"] == false {
				continue
			}
			n := str(fallback(it["name"], it["entry"]))
			key := group.kind + ":" + n
			if !pathName.MatchString(n) {
				miss[key] = "имя пути: только буквы, цифры, _ и -"
				continue
			}
			if group.kind == "cdn" {
				e, err := entry(str(it["entry"]))
				if err != nil {
					miss[key] = err.Error()
					continue
				}
				x := obj(e["secrets"])
				if str(x["ws_uuid"]) == "" || str(x["ws_path"]) == "" || str(it["domain"]) == "" {
					miss[key] = "узел не содержит WebSocket или domain"
					continue
				}
				tag := "cdn-" + n
				add("cdn", []object{with(wsOutbound(it["domain"], it["domain"], 443, x["ws_uuid"], fallback(it["path"], x["ws_path"]), false, true), "tag", tag)}, tag)
				continue
			}
			if vl == nil {
				miss[key] = "в channel нет VLESS"
				continue
			}
			if group.kind == "relay" {
				host := fallback(it["host"], it["server"])
				port := num(it["port"])
				if str(host) == "" || port == 0 {
					miss[key] = "нет host или port"
					continue
				}
				tag := "vless-relay-" + n
				add("relay", []object{with(vl, "tag", tag, "server", host, "server_port", port)}, tag)
			} else {
				h, err := hopOutbound(with(it, "name", n))
				if err != nil {
					miss[key] = err.Error()
					continue
				}
				tag := "vless-sshhop-" + n
				add("hop", []object{h, with(vl, "tag", tag, "detour", h["tag"], "server", server)}, tag)
			}
		}
	}
	add("ssh", []object{{"type": "direct", "tag": "ssh-direct"}}, "ssh-direct")
	if vl != nil {
		add("vless", []object{with(vl, "tag", "vless-direct", "server", server)}, "vless-direct")
	}
	ws := []object{}
	for _, w := range cfg.Paths.WSEntries {
		n := "ws-" + str(w["name"])
		if vl == nil || !pathName.MatchString(n) || num(w["port"]) == 0 || str(w["host"]) == "" || str(w["path"]) == "" {
			miss["ws:"+str(w["name"])] = "нет VLESS или неверные параметры WebSocket"
			continue
		}
		o := wsOutbound(fallback(w["address"], w["host"]), w["host"], num(w["port"]), vl["uuid"], w["path"], true, false)
		o["tag"] = n
		if w["certificate"] != nil && w["certificate"] != "" {
			delete(obj(o["tls"]), "insecure")
			obj(o["tls"])["certificate"] = w["certificate"]
		}
		add("ws", []object{o}, n)
		ws = append(ws, o)
	}
	for _, port := range proxyPorts {
		tag := "socks" + strconv.Itoa(port)
		so := object{"type": "socks", "tag": tag, "server": "127.0.0.1", "server_port": port, "version": "5"}
		add("proxy", []object{so}, tag)
		for _, o := range ws {
			name := str(o["tag"]) + "-" + tag
			add("proxy", []object{so, with(o, "tag", name, "detour", tag)}, name)
		}
		if vl != nil {
			name := "vless-" + tag
			add("proxy", []object{so, with(vl, "tag", name, "detour", tag, "server", server)}, name)
		}
	}
	if vpnInterface != "" {
		base := append([]api.ChannelPath(nil), paths...)
		for _, p := range base {
			if p.Kind == "proxy" {
				continue
			}
			ren := map[string]string{}
			for _, o := range p.Outbounds {
				ren[str(o["tag"])] = str(o["tag"]) + "-vpn"
			}
			outs := []object{}
			for _, o := range p.Outbounds {
				q := with(o, "tag", ren[str(o["tag"])])
				if d := str(o["detour"]); d != "" {
					q["detour"] = fallback(ren[d], d)
				} else {
					q["bind_interface"] = vpnInterface
				}
				outs = append(outs, q)
			}
			paths = append(paths, api.ChannelPath{Name: ren[p.Final], Final: ren[p.Final], Kind: p.Kind, Node: p.Node + " через " + vpnInterface, Outbounds: outs})
		}
	}
	seen := map[string]bool{}
	unique := []api.ChannelPath{}
	for _, p := range paths {
		if !seen[p.Name] && len(unique) < 64 {
			unique = append(unique, p)
			seen[p.Name] = true
		}
	}
	return unique, miss
}

func hopOutbound(h object) (object, error) {
	m := hopName.FindStringSubmatch(str(fallback(h["ssh"], h["alias"])))
	if m == nil {
		return nil, errors.New("hop: нужен логин@хост[:порт]")
	}
	port := 22
	if m[3] != "" {
		port = num(m[3])
	}
	key := str(h["keyFile"])
	st, err := os.Stat(key)
	if port < 1 || port > 65535 || err != nil || !st.Mode().IsRegular() {
		return nil, errors.New("hop: неверный порт или нет keyFile")
	}
	kh := str(h["knownHostsPath"])
	keys := knownHostKeys(kh, m[2], port)
	if len(keys) == 0 {
		if pin, ok := h["hostKey"].(string); ok {
			keys = []string{pin}
		} else {
			for _, k := range arr(h["hostKey"]) {
				if s, ok := k.(string); ok {
					keys = append(keys, s)
				}
			}
		}
	}
	if len(keys) == 0 && kh == "" {
		home, _ := os.UserHomeDir()
		keys = knownHostKeys(filepath.Join(home, ".ssh", "known_hosts"), m[2], port)
	}
	if len(keys) == 0 {
		return nil, errors.New("нет закреплённого ключа хоста SSH-перехода")
	}
	algs := []string{}
	for _, k := range keys {
		f := strings.Fields(k)
		if len(f) == 0 {
			continue
		}
		if f[0] == "ssh-rsa" {
			algs = append(algs, "rsa-sha2-512", "rsa-sha2-256")
		} else {
			algs = append(algs, f[0])
		}
	}
	o := object{"type": "ssh", "tag": "hop-" + str(h["name"]), "server": m[2], "server_port": port, "user": m[1], "private_key_path": key, "host_key": keys}
	if len(algs) > 0 {
		o["host_key_algorithms"] = algs
	}
	return o, nil
}
func knownHostKeys(path, host string, port int) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	b, _ := io.ReadAll(io.LimitReader(f, 4<<20))
	name := host
	if port != 22 {
		name = fmt.Sprintf("[%s]:%d", host, port)
	}
	keys := []string{}
	lines := strings.Split(strings.ReplaceAll(strings.TrimPrefix(string(b), "\ufeff"), "\r", ""), "\n")
	for i, line := range lines {
		if i >= 20000 {
			break
		}
		p := strings.Fields(line)
		if len(p) < 3 || strings.HasPrefix(p[0], "#") || strings.HasPrefix(p[0], "@") {
			continue
		}
		if (strings.HasPrefix(p[1], "ssh-") || strings.HasPrefix(p[1], "ecdsa-")) && hostMatch(p[0], name) {
			k := p[1] + " " + p[2]
			if !contains(keys, k) {
				keys = append(keys, k)
			}
		}
	}
	return keys
}
func hostMatch(field, name string) bool {
	if strings.HasPrefix(field, "|1|") {
		p := strings.Split(field, "|")
		if len(p) != 4 {
			return false
		}
		salt, e := base64.StdEncoding.DecodeString(p[2])
		if e != nil {
			return false
		}
		mac := hmac.New(sha1.New, salt)
		mac.Write([]byte(name))
		return hmac.Equal([]byte(base64.StdEncoding.EncodeToString(mac.Sum(nil))), []byte(p[3]))
	}
	ok := false
	for _, pat := range strings.Split(field, ",") {
		neg := strings.HasPrefix(pat, "!")
		pat = strings.TrimPrefix(pat, "!")
		expr := regexp.QuoteMeta(strings.ToLower(pat))
		expr = strings.ReplaceAll(strings.ReplaceAll(expr, `\*`, ".*"), `\?`, ".")
		matched, _ := regexp.MatchString("^"+expr+"$", strings.ToLower(name))
		if matched {
			if neg {
				return false
			}
			ok = true
		}
	}
	return ok
}

func Render(rc api.RenderContext) ([]byte, error) {
	if rc.Cfg == nil || len(rc.Cfg.Servers) == 0 {
		return nil, errors.New("singbox: нет сервера")
	}
	paths := rc.Paths
	if paths == nil {
		paths, _ = BuildPaths(rc.Cfg, rc.ProxyPorts, rc.VPNInterface)
	}
	if len(paths) == 0 {
		return nil, errors.New("singbox: нет путей")
	}
	ins, rules, outs := []object{}, []object{}, []object{}
	names := []string{}
	tags := map[string]bool{}
	server := rc.Cfg.Servers[0]
	port := server.Port
	if port == 0 {
		port = 22
	}
	inbound := func(name string, p int) {
		ins = append(ins, object{"type": "direct", "tag": "in-" + name, "listen": "127.0.0.1", "listen_port": p, "override_address": server.Host, "override_port": port})
	}
	for _, p := range paths {
		if p.Name != "chan" && !contains(names, p.Name) {
			names = append(names, p.Name)
		}
		listen := rc.Ports[p.Name]
		if listen == 0 && p.Name == "chan" {
			listen = rc.ChanPort
		}
		if listen == 0 {
			return nil, fmt.Errorf("singbox: нет порта пути %s", p.Name)
		}
		inbound(p.Name, listen)
		rules = append(rules, object{"inbound": "in-" + p.Name, "outbound": p.Final})
		for _, o := range p.Outbounds {
			tag := str(o["tag"])
			if tags[tag] {
				continue
			}
			tags[tag] = true
			q := clone(o)
			if contains([]string{"vless", "trojan", "shadowtls", "ssh", "vmess", "shadowsocks", "direct"}, str(o["type"])) && str(o["detour"]) == "" {
				q["tcp_keep_alive"] = "15s"
				q["tcp_keep_alive_interval"] = "5s"
			}
			outs = append(outs, q)
		}
	}
	if rc.ChanPort != 0 && len(names) > 0 && !tags["chan"] {
		inbound("chan", rc.ChanPort)
		outs = append(outs, object{"type": "selector", "tag": "chan", "outbounds": names, "default": names[0], "interrupt_exist_connections": false})
		rules = append(rules, object{"inbound": "in-chan", "outbound": "chan"})
	}
	return json.Marshal(object{"log": object{"level": "info"}, "inbounds": ins, "outbounds": outs, "route": object{"rules": rules, "auto_detect_interface": true}, "experimental": object{"clash_api": object{"external_controller": fmt.Sprintf("127.0.0.1:%d", rc.ClashPort), "secret": rc.ClashSecret}}})
}
