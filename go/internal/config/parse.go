package config

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"remoteagents/internal/api"
	"remoteagents/internal/secret"
)

const (
	maxBytes = 1 << 20
	kdfMax   = 5_000_000
)

var (
	nameRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$`)
	enc1Re = regexp.MustCompile(`^enc1:[A-Za-z0-9+/]{64,}={0,2}$`)
	chanRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
	toRe   = regexp.MustCompile(`^[^\s:]+:[0-9]{1,5}$`)
	digits = regexp.MustCompile(`^[0-9]{1,5}$`)

	entryKinds = []string{"hy2", "hy2obfs", "tuic", "trojan", "reality", "shadowtls", "ws-direct", "ws-cdn"}
	known      = map[string]bool{"format": true, "name": true, "server": true, "paths": true, "vpn": true, "control": true,
		"controlRunAs": true, "autostart": true, "lan": true, "tun": true, "happier": true, "forwards": true, "lanProxy": true,
		"disk": true, "syncPort": true, "update": true, "kdf": true, "check": true}

	// ruDomains: vpn.direct.domains default (v2 vpn.py RU_DOMAINS).
	ruDomains = []string{"ru", "su", "xn--p1ai", "xn--p1acf", "xn--80adxhks", "xn--d1acj3b", "xn--80asehdb", "xn--80aswg", "xn--c1avg",
		"yandex.net", "yandex.com", "yastatic.net", "yandexcloud.net", "ya.cc", "vk.com", "vk.me", "vkuser.net", "userapi.com",
		"vk-cdn.net", "mycdn.me", "okcdn.ru", "mail.ru", "avito.st", "wbstatic.net", "wbbasket.ru", "ozone.ru", "tbank-online.com"}
)

type obj = map[string]any

type checker struct{ pr []Problem }

func (c *checker) add(stage, code, field, msg string) {
	c.pr = append(c.pr, Problem{Stage: stage, Code: code, Field: field, Msg: msg})
}
func (c *checker) schema(field, msg string) { c.add("schema", "schema", field, msg) }

func decodeJSON(data []byte) (obj, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err == nil {
		return nil, errTrailing
	}
	m, ok := v.(obj)
	if !ok {
		return nil, errTrailing
	}
	return m, nil
}

type parseErr string

func (e parseErr) Error() string { return string(e) }

const errTrailing = parseErr("not an object")

func trimBOM(b []byte) []byte { return bytes.TrimPrefix(b, []byte{0xef, 0xbb, 0xbf}) }

func asInt(v any) (int, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	i, err := n.Int64()
	if err != nil || i < -1<<31 || i > 1<<31 {
		return 0, false
	}
	return int(i), true
}
func isPort(v any) bool { i, ok := asInt(v); return ok && i >= 1 && i <= 65535 }
func text(v any) (string, bool) {
	s, ok := v.(string)
	return s, ok && strings.TrimSpace(s) != ""
}

// Parse = stages json, schema, semantic (equals v2 `v2config check`, no password).
func Parse(data []byte) (*api.Config, []Problem) {
	data = trimBOM(data)
	c := &checker{}
	if len(data) == 0 || len(data) > maxBytes {
		c.add("semantic", "size", "", "config is empty or larger than 1 MiB")
		return nil, c.pr
	}
	root, err := decodeJSON(data)
	if err != nil {
		c.add("json", "json", "", "not a JSON object")
		return nil, c.pr
	}
	if f, _ := root["format"].(string); f != "remoteagents-2" {
		c.add("schema", "format", "format", "format must be remoteagents-2")
		return nil, c.pr
	}
	c.validate(root)
	if len(c.pr) > 0 {
		return nil, c.pr
	}
	return normalize(root, data), nil
}

func (c *checker) enc(field string, v any) {
	s, ok := v.(string)
	switch {
	case !ok:
		c.schema(field, "must be an enc1 string")
	case !strings.HasPrefix(s, "enc1:"):
		c.add("semantic", "secret-plain", field, "secret is not encrypted")
	case !enc1Re.MatchString(s):
		c.schema(field, "malformed enc1 value")
	}
}

func (c *checker) optBool(m obj, key, field string) {
	if v, ok := m[key]; ok {
		if _, isB := v.(bool); !isB {
			c.schema(field, "must be boolean")
		}
	}
}
func (c *checker) optPort(m obj, key, field string) {
	if v, ok := m[key]; ok && !isPort(v) {
		c.add("schema", "port", field, "port must be 1..65535")
	}
}
func (c *checker) object(v any, field string) (obj, bool) {
	m, ok := v.(obj)
	if !ok {
		c.schema(field, "must be an object")
	}
	return m, ok
}

func (c *checker) validate(root obj) {
	if _, ok := root["servers"]; ok {
		c.add("semantic", "multi-server", "servers", "several servers are not supported")
	}
	if s, ok := text(root["name"]); !ok || utf8.RuneCountInString(s) > 80 {
		c.add("schema", "name", "name", "name is required (1..80 chars)")
	}
	// server
	if srv, ok := root["server"].(obj); !ok {
		c.add("schema", "server", "server", "server section is required")
	} else {
		for _, k := range []string{"host", "user", "hostKey"} {
			if _, ok := text(srv[k]); !ok {
				c.add("schema", "server", "server."+k, "required text")
			}
		}
		if v, ok := srv["key"]; !ok || v == "" {
			c.add("schema", "server", "server.key", "required text")
		} else {
			c.enc("server.key", v)
		}
		if _, has := srv["port"]; has && !isPort(srv["port"]) {
			c.add("schema", "port", "server.port", "port must be 1..65535")
		}
	}
	// vpn
	if v, ok := root["vpn"]; ok {
		if vpn, ok := c.object(v, "vpn"); ok {
			if m, has := vpn["mode"]; has {
				if s, _ := m.(string); s != "off" && s != "auto" && s != "only" {
					c.add("schema", "vpn-mode", "vpn.mode", "mode must be off, auto or only")
				}
			}
			if b, has := vpn["bridges"]; has {
				c.names(b, "vpn.bridges")
			}
			if d, has := vpn["direct"]; has {
				if dm, ok := c.object(d, "vpn.direct"); ok {
					if dom, has := dm["domains"]; has {
						arr, ok := dom.([]any)
						if !ok {
							c.schema("vpn.direct.domains", "must be an array")
						}
						for _, x := range arr {
							if _, ok := text(x); !ok {
								c.schema("vpn.direct.domains", "items must be non-empty text")
								break
							}
						}
					}
				}
			}
		}
	}
	// kdf / check (v2 `check`: the config must be sealed)
	if v, ok := root["kdf"]; ok {
		if kdf, ok := v.(obj); !ok {
			c.add("schema", "kdf", "kdf", "invalid password parameters")
		} else {
			if it, ok := asInt(kdf["iterations"]); !ok || it < 1 || it > kdfMax {
				c.add("schema", "kdf", "kdf.iterations", "iterations must be 1..5000000")
			}
			if s, ok := text(kdf["salt"]); !ok {
				c.add("schema", "kdf", "kdf.salt", "salt is required")
			} else if _, err := base64.StdEncoding.DecodeString(s); err != nil {
				c.add("schema", "kdf", "kdf.salt", "salt must be base64")
			}
		}
	}
	if s, _ := root["check"].(string); !strings.HasPrefix(s, "enc1:") || root["kdf"] == nil {
		c.add("semantic", "sealed", "check", "config is not sealed (kdf or check missing)")
	} else if !enc1Re.MatchString(s) {
		c.schema("check", "malformed enc1 value")
	}
	c.optBool(root, "control", "control")
	c.optBool(root, "autostart", "autostart")
	if v, ok := root["controlRunAs"]; ok {
		if _, isS := v.(string); !isS {
			c.schema("controlRunAs", "must be a string")
		}
	}
	c.validatePaths(root)
	c.validateRest(root)
}

func (c *checker) names(v any, field string) {
	arr, ok := v.([]any)
	if !ok {
		c.schema(field, "must be an array")
		return
	}
	for _, x := range arr {
		if s, _ := x.(string); !nameRe.MatchString(s) {
			c.add("schema", "names", field, "invalid node name")
			return
		}
	}
}

func (c *checker) validatePaths(root obj) {
	paths, ok := root["paths"].(obj)
	if !ok {
		c.add("schema", "paths", "paths", "paths section is required")
		return
	}
	secrets, _ := paths["secrets"].(obj)
	if v, has := paths["secrets"]; has {
		if secrets == nil {
			c.schema("paths.secrets", "must be an object")
		}
		for _, n := range sortedKeys(secrets) {
			if !nameRe.MatchString(n) {
				c.add("schema", "names", "paths.secrets", "invalid secret name")
				break
			}
		}
		for _, n := range sortedKeys(secrets) {
			c.enc("paths.secrets."+n, secrets[n])
		}
		_ = v
	}
	working := false
	if v, has := paths["channel"]; has && v != "" && v != nil {
		c.enc("paths.channel", v)
		working = true
	}
	if v, has := paths["entries"]; has {
		arr, ok := v.([]any)
		if !ok {
			c.schema("paths.entries", "must be an array")
		}
		badName := false
		for _, e := range arr {
			var name string
			enabled := true
			switch t := e.(type) {
			case string:
				name = t
			case obj:
				name, _ = t["name"].(string)
				if en, has := t["enabled"]; has {
					b, isB := en.(bool)
					if !isB {
						c.schema("paths.entries.enabled", "must be boolean")
					}
					enabled = b || !isB
				}
				if k, has := t["kinds"]; has {
					ka, isA := k.([]any)
					if !isA {
						c.schema("paths.entries.kinds", "must be an array")
					}
					for _, x := range ka {
						if s, _ := x.(string); !contains(entryKinds, s) {
							c.schema("paths.entries.kinds", "unknown kind")
							break
						}
					}
				}
			default:
				c.add("schema", "names", "paths.entries", "invalid node name")
				continue
			}
			if !nameRe.MatchString(name) {
				if !badName {
					c.add("schema", "names", "paths.entries", "invalid node name")
				}
				badName = true
				continue
			}
			if _, has := secrets[name]; has && enabled {
				working = true
			}
		}
	}
	for _, k := range []string{"relays", "hops", "cdn", "wsEntries"} {
		v, has := paths[k]
		if !has {
			continue
		}
		arr, ok := v.([]any)
		if !ok {
			c.schema("paths."+k, "must be an array")
		}
		for _, x := range arr {
			m, isO := x.(obj)
			if !isO {
				c.schema("paths."+k, "items must be objects")
				break
			}
			if en, has := m["enabled"].(bool); !has || en {
				working = true
			}
		}
	}
	if !working {
		c.add("semantic", "paths", "paths", "no working path (enabled entry with secret, channel, relay, hop, cdn or ws)")
	}
}

func (c *checker) validateRest(root obj) {
	if v, ok := root["lan"]; ok {
		arr, ok := v.([]any)
		if !ok {
			c.schema("lan", "must be an array")
		}
		for _, x := range arr {
			m, ok := x.(obj)
			if !ok {
				c.schema("lan", "items must be objects")
				continue
			}
			for _, k := range []string{"name", "host"} {
				if _, ok := text(m[k]); !ok {
					c.schema("lan."+k, "required text")
				}
			}
			c.optPort(m, "port", "lan.port")
			c.optPort(m, "testPort", "lan.testPort")
			if v, has := m["testHost"]; has {
				if _, isS := v.(string); !isS {
					c.schema("lan.testHost", "must be a string")
				}
			}
			if sh, has := m["share"]; has {
				if sm, ok := c.object(sh, "lan.share"); ok {
					c.optBool(sm, "enabled", "lan.share.enabled")
					for _, k := range []string{"subnets", "domains"} {
						if l, has := sm[k]; has && !allStrings(l) {
							c.schema("lan.share."+k, "must be an array of strings")
						}
					}
				}
			}
		}
	}
	if v, ok := root["tun"]; ok {
		if m, ok := c.object(v, "tun"); ok {
			c.optBool(m, "enabled", "tun.enabled")
			if a, has := m["address"]; has {
				if _, isS := a.(string); !isS {
					c.schema("tun.address", "must be a string")
				}
			}
		}
	}
	if v, ok := root["happier"]; ok {
		if m, ok := c.object(v, "happier"); ok {
			if lw, has := m["localWeb"]; has {
				if lm, ok := c.object(lw, "happier.localWeb"); ok {
					c.optBool(lm, "enabled", "happier.localWeb.enabled")
					c.optPort(lm, "port", "happier.localWeb.port")
					c.optPort(lm, "serverPort", "happier.localWeb.serverPort")
				}
			}
		}
	}
	if v, ok := root["forwards"]; ok {
		arr, ok := v.([]any)
		if !ok {
			c.schema("forwards", "must be an array")
		}
		if len(arr) > 16 {
			c.schema("forwards", "at most 16 forwards")
		}
		for _, x := range arr {
			m, ok := x.(obj)
			if !ok {
				c.schema("forwards", "items must be objects")
				continue
			}
			if _, ok := listenPort(m["listen"]); !ok {
				c.add("semantic", "forwards.listen", "forwards.listen", "listen must be a port 1..65535")
			}
			if to, _ := m["to"].(string); !toRe.MatchString(to) || !isPortStr(to[strings.LastIndexByte(to, ':')+1:]) {
				c.schema("forwards.to", "to must be host:port")
			}
		}
	}
	if v, ok := root["lanProxy"]; ok {
		if m, ok := c.object(v, "lanProxy"); ok {
			c.optPort(m, "port", "lanProxy.port")
		}
	}
	if v, ok := root["disk"]; ok {
		c.object(v, "disk")
	}
	if v, ok := root["syncPort"]; ok {
		if _, isI := asInt(v); !isI {
			c.schema("syncPort", "must be an integer")
		}
	}
	if v, ok := root["update"]; ok {
		if m, ok := c.object(v, "update"); ok {
			c.optBool(m, "auto", "update.auto")
			if ch, has := m["channel"]; has {
				if s, _ := ch.(string); !chanRe.MatchString(s) {
					c.schema("update.channel", "invalid channel name")
				}
			}
		}
	}
}

func isPortStr(s string) bool {
	if !digits.MatchString(s) {
		return false
	}
	n := 0
	for _, r := range s {
		n = n*10 + int(r-'0')
	}
	return n >= 1 && n <= 65535
}

func listenPort(v any) (int, bool) {
	if s, ok := v.(string); ok {
		if !isPortStr(s) {
			return 0, false
		}
		n := 0
		for _, r := range s {
			n = n*10 + int(r-'0')
		}
		return n, true
	}
	if isPort(v) {
		n, _ := asInt(v)
		return n, true
	}
	return 0, false
}

func allStrings(v any) bool {
	arr, ok := v.([]any)
	if !ok {
		return false
	}
	for _, x := range arr {
		if _, ok := x.(string); !ok {
			return false
		}
	}
	return true
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

func sortedKeys(m obj) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func raw(v any) json.RawMessage { b, _ := json.Marshal(v); return b }

func strOf(v any) string { s, _ := v.(string); return s }

func intOf(v any, def int) int {
	if i, ok := asInt(v); ok {
		return i
	}
	return def
}

func boolOf(m obj, key string, def bool) bool {
	if b, ok := m[key].(bool); ok {
		return b
	}
	return def
}

func strList(v any) []string {
	arr, _ := v.([]any)
	out := make([]string, 0, len(arr))
	for _, x := range arr {
		if s, ok := x.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func maps(v any) []map[string]any {
	arr, _ := v.([]any)
	var out []map[string]any
	for _, x := range arr {
		if m, ok := x.(obj); ok {
			out = append(out, m)
		}
	}
	return out
}

// normalize maps validated JSON to the model (api C2). Secrets stay empty until Open.
func normalize(root obj, data []byte) *api.Config {
	c := &api.Config{Format: "remoteagents-2", Name: strOf(root["name"]), Raw: append(json.RawMessage(nil), data...)}
	srv, _ := root["server"].(obj)
	c.Servers = []api.Server{{Host: strOf(srv["host"]), Port: intOf(srv["port"], 22), User: strOf(srv["user"]), HostKey: strings.TrimSpace(strOf(srv["hostKey"]))}}
	paths, _ := root["paths"].(obj)
	for _, e := range func() []any { a, _ := paths["entries"].([]any); return a }() {
		switch t := e.(type) {
		case string:
			c.Paths.Entries = append(c.Paths.Entries, api.EntryRef{Name: t, Enabled: true, Kinds: entryKinds})
		case obj:
			er := api.EntryRef{Name: strOf(t["name"]), Enabled: boolOf(t, "enabled", true), Kinds: entryKinds, Extra: map[string]json.RawMessage{}}
			if _, has := t["kinds"]; has {
				er.Kinds = strList(t["kinds"])
			}
			for k, v := range t {
				if k != "name" && k != "enabled" && k != "kinds" {
					er.Extra[k] = raw(v)
				}
			}
			c.Paths.Entries = append(c.Paths.Entries, er)
		}
	}
	c.Paths.Relays, c.Paths.Hops = maps(paths["relays"]), maps(paths["hops"])
	c.Paths.CDN, c.Paths.WSEntries = maps(paths["cdn"]), maps(paths["wsEntries"])
	if s, _ := paths["secrets"].(obj); len(s) > 0 {
		c.Paths.Secrets = map[string]json.RawMessage{}
		for k := range s {
			c.Paths.Secrets[k] = nil
		}
	}
	vpn, _ := root["vpn"].(obj)
	c.VPN = api.VPNCfg{Mode: "off", Bridges: strList(vpn["bridges"]), Direct: api.VPNDirect{Domains: ruDomains}}
	if m, ok := vpn["mode"].(string); ok {
		c.VPN.Mode = m
	}
	if d, ok := vpn["direct"].(obj); ok {
		if _, has := d["domains"]; has {
			c.VPN.Direct.Domains = strList(d["domains"])
		}
		if g, has := d["geoip"]; has {
			c.VPN.Direct.GeoIP = raw(g)
		}
	}
	for _, m := range maps(root["lan"]) {
		l := api.LANCfg{Name: strOf(m["name"]), Host: strOf(m["host"]), TestHost: strOf(m["testHost"]),
			Port: intOf(m["port"], 22), TestPort: intOf(m["testPort"], 0)}
		sh, _ := m["share"].(obj)
		l.Share = api.LANShare{Enabled: boolOf(sh, "enabled", true), Subnets: strList(sh["subnets"]), Domains: strList(sh["domains"])}
		c.LAN = append(c.LAN, l)
	}
	tun, _ := root["tun"].(obj)
	c.Tun = api.TunCfg{Enabled: boolOf(tun, "enabled", false), Address: "172.19.0.1/30"}
	if a := strOf(tun["address"]); a != "" {
		c.Tun.Address = a
	}
	if h, ok := root["happier"].(obj); ok {
		if lw, ok := h["localWeb"].(obj); ok {
			c.Happier.LocalWeb = &api.LocalWeb{Enabled: boolOf(lw, "enabled", false), Port: intOf(lw["port"], 0), ServerPort: intOf(lw["serverPort"], 0)}
		}
	}
	for _, m := range maps(root["forwards"]) {
		l, _ := listenPort(m["listen"])
		to := strOf(m["to"])
		i := strings.LastIndexByte(to, ':')
		p, _ := listenPort(to[i+1:])
		c.Forwards = append(c.Forwards, api.ForwardCfg{Listen: l, ToHost: to[:i], ToPort: p})
	}
	if lp, ok := root["lanProxy"].(obj); ok {
		c.LanProxy = &api.LanProxyCfg{Port: intOf(lp["port"], 0)}
	}
	c.Control = api.ControlCfg{Enabled: boolOf(root, "control", true), RunAs: strOf(root["controlRunAs"])}
	c.Autostart = boolOf(root, "autostart", false) // autostart is OFF by default during v3 development (owner, 26.11)
	up, _ := root["update"].(obj)
	c.Update = api.UpdateCfg{Auto: boolOf(up, "auto", true), Channel: "v3-latest"}
	if ch := strOf(up["channel"]); ch != "" {
		c.Update.Channel = ch
	}
	if d, ok := root["disk"]; ok {
		c.Disk = raw(d)
	}
	for _, k := range sortedKeys(root) {
		if !known[k] {
			c.Unknown = append(c.Unknown, k)
		}
	}
	return c
}

// kdfOf derives the 64-byte key from the (already validated) kdf section.
func kdfOf(root obj, password string) ([]byte, error) {
	kdf, _ := root["kdf"].(obj)
	salt, _ := base64.StdEncoding.DecodeString(strOf(kdf["salt"]))
	it, _ := asInt(kdf["iterations"])
	return secret.Derive(password, salt, it)
}
