// Package config reads and applies remoteagents-2 configs, as v2config.py does.
package config

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"regexp"
	"strconv"
	"strings"

	"remoteagents/internal/api"
	"remoteagents/internal/secret"
)

var ErrNoConfig = errors.New("config: no-config")

type Problem struct{ Stage, Code, Field, Msg string }
type CheckError struct{ Problems []Problem }

func (e *CheckError) Error() string { return "config: check failed" }

var nameRE = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$`)

type object = map[string]any

func obj(v any) object {
	m, _ := v.(map[string]any)
	if m == nil {
		return object{}
	}
	return m
}
func str(v any) string { s, _ := v.(string); return s }
func integer(v any, fallback int) int {
	if v == nil {
		return fallback
	}
	switch n := v.(type) {
	case float64:
		if n == float64(int(n)) {
			return int(n)
		}
	case string:
		i, err := strconv.Atoi(n)
		if err == nil {
			return i
		}
	}
	return 0
}
func truth(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case string:
		return x != ""
	case []any:
		return len(x) > 0
	case map[string]any:
		return len(x) > 0
	case float64:
		return x != 0
	}
	return true
}
func raw(v any) json.RawMessage { b, _ := json.Marshal(v); return b }
func decode(v any, dst any)     { _ = json.Unmarshal(raw(v), dst) }

func Parse(data []byte) (*api.Config, []Problem) {
	var problems []Problem
	bad := func(field, message string) {
		problems = append(problems, Problem{Stage: "config", Field: field, Msg: message})
	}
	if len(data) > 1024*1024 {
		bad("", "Конфиг слишком большой или пустой.")
		return nil, problems
	}
	data = bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})
	var root object
	if json.Unmarshal(data, &root) != nil || root == nil || root["format"] != "remoteagents-2" {
		bad("", "Это не конфиг RemoteAgents.")
		return nil, problems
	}
	srv, paths := obj(root["server"]), obj(root["paths"])
	// Task-specific extension: a VPN-only config needs neither SSH nor channel paths.
	_, serverPresent := root["server"]
	_, pathsPresent := root["paths"]
	vpnOnly := root["vpn"] != nil && !serverPresent && !pathsPresent
	if strings.TrimSpace(str(root["name"])) == "" {
		bad("name", "В конфиге нет имени.")
	}
	if !vpnOnly {
		for _, k := range []string{"host", "user", "hostKey", "key"} {
			if strings.TrimSpace(str(srv[k])) == "" {
				bad("server."+k, "В конфиге нет сведений о сервере ("+k+").")
			}
		}
		p, ok := srv["port"].(float64)
		if srv["port"] != nil && (!ok || p != float64(int(p)) || p < 1 || p > 65535) {
			bad("server.port", "В конфиге неверный порт сервера.")
		}
		if !truth(paths["entries"]) && !truth(paths["channel"]) {
			bad("paths", "В конфиге нет путей канала.")
		}
	}
	if v := root["vpn"]; v != nil {
		m, ok := v.(map[string]any)
		mode := "off"
		if m["mode"] != nil {
			mode = str(m["mode"])
		}
		if !ok || (mode != "off" && mode != "auto" && mode != "only") {
			bad("vpn", "Неверный режим VPN (допустимо: off, auto, only).")
		}
	}
	if k := root["kdf"]; k != nil {
		m, ok := k.(map[string]any)
		n, numeric := m["iterations"].(float64)
		if !ok || !numeric || n != float64(int(n)) || n < 1 || n > 5000000 {
			bad("kdf", "Неверные параметры пароля в конфиге.")
		}
	}
	if entries, ok := paths["entries"].([]any); ok {
		for _, e := range entries {
			n := str(e)
			if m, ok := e.(map[string]any); ok {
				n = str(m["name"])
			}
			if !nameRE.MatchString(n) {
				bad("paths.entries", "Неверное имя узла входа.")
				break
			}
		}
	} else if truth(paths["entries"]) {
		bad("paths.entries", "Неверное имя узла входа.")
	}
	if s := paths["secrets"]; truth(s) {
		if _, ok := s.(map[string]any); !ok {
			bad("paths.secrets", "Неверный раздел секретов.")
		}
	}
	for n := range obj(paths["secrets"]) {
		if !nameRE.MatchString(n) {
			bad("paths.secrets", "Неверное имя секрета узла.")
			break
		}
	}
	if len(problems) > 0 {
		return nil, problems
	}
	c := normalize(root)
	c.Raw = append(json.RawMessage(nil), data...)
	c.VPNOnly = vpnOnly
	return c, nil
}

func normalize(root object) *api.Config {
	c := &api.Config{Format: str(root["format"]), Name: str(root["name"]), Sections: map[string]json.RawMessage{}}
	for k, v := range root {
		c.Sections[k] = raw(v)
	}
	if s, ok := root["server"].(map[string]any); ok {
		c.Servers = []api.Server{{Host: str(s["host"]), Port: integer(s["port"], 22), User: str(s["user"]), HostKey: str(s["hostKey"])}}
	}
	p := obj(root["paths"])
	entries, _ := p["entries"].([]any)
	for _, e := range entries {
		m := obj(e)
		if s, ok := e.(string); ok {
			m = object{"name": s}
		}
		entry := api.EntryRef{Name: str(m["name"]), Enabled: m["enabled"] != false, Extra: map[string]json.RawMessage{}}
		decode(m["kinds"], &entry.Kinds)
		for k, v := range m {
			entry.Extra[k] = raw(v)
		}
		c.Paths.Entries = append(c.Paths.Entries, entry)
	}
	// v2 _items also accepts string references for relays/hops/CDN/wsEntries.
	for k, dst := range map[string]*[]map[string]any{"relays": &c.Paths.Relays, "hops": &c.Paths.Hops, "cdn": &c.Paths.CDN, "wsEntries": &c.Paths.WSEntries} {
		items, _ := p[k].([]any)
		for _, v := range items {
			if s, ok := v.(string); ok {
				*dst = append(*dst, object{"name": s})
			} else if m, ok := v.(map[string]any); ok {
				*dst = append(*dst, m)
			}
		}
	}
	decode(root["vpn"], &c.VPN)
	if c.VPN.Mode == "" {
		c.VPN.Mode = "off"
	}
	decode(root["tun"], &c.Tun)
	decode(root["happier"], &c.Happier)
	decode(root["lanProxy"], &c.LanProxy)
	decode(root["update"], &c.Update)
	c.Control.Enabled = truth(root["control"])
	c.Autostart = truth(root["autostart"])
	if root["disk"] != nil {
		c.Disk = raw(root["disk"])
	}
	lans := root["lan"]
	if lans == nil {
		lans = obj(root["profile"])["lan"]
	}
	items, _ := lans.([]any)
	seen := map[string]bool{}
	for _, v := range items {
		m := obj(v)
		n := str(m["name"])
		if n == "" || seen[n] {
			continue
		}
		seen[n] = true
		share := obj(m["share"])
		host := str(m["testHost"])
		if host == "" {
			host = str(m["host"])
		}
		port := m["testPort"]
		if !truth(port) {
			port = m["port"]
		}
		if !truth(port) {
			port = float64(22)
		}
		nport, ok := port.(float64)
		if share["enabled"] == false || host == "" || !ok || nport != float64(int(nport)) || nport < 1 || nport > 65535 {
			continue
		}
		lan := api.LANCfg{Name: n, Host: host, Port: int(nport), TestHost: host, TestPort: int(nport), Share: api.LANShare{Enabled: true}}
		decode(share["subnets"], &lan.Share.Subnets)
		decode(share["domains"], &lan.Share.Domains)
		c.LAN = append(c.LAN, lan)
		if len(c.LAN) == 64 {
			break
		}
	}
	forwards, _ := root["forwards"].([]any)
	for _, v := range forwards {
		m := obj(v)
		dest := str(m["to"])
		host, port, ok := "", "", false
		if i := strings.LastIndex(dest, ":"); i >= 0 {
			host, port, ok = dest[:i], dest[i+1:], true
		}
		listen := integer(m["listen"], 0)
		target := integer(port, 0)
		if ok && listen > 0 && listen < 65536 && target > 0 && target < 65536 {
			c.Forwards = append(c.Forwards, api.ForwardCfg{Listen: listen, ToHost: host, ToPort: target})
		}
	}
	return c
}

func Open(data []byte, password string) (*api.Config, []byte, error) {
	c, problems := Parse(data)
	if len(problems) > 0 {
		return nil, nil, &CheckError{problems}
	}
	// VPN-only configs with no secrets may be supplied without a password envelope.
	if c.VPNOnly && c.Sections["kdf"] == nil && c.Sections["check"] == nil {
		return c, nil, nil
	}
	var kdf struct {
		Salt       string
		Iterations int
	}
	var check string
	if c.Section("kdf", &kdf) != nil || c.Section("check", &check) != nil || kdf.Iterations == 0 || check == "" {
		return nil, nil, errors.New("Конфиг не защищён паролем.")
	}
	salt, err := base64.StdEncoding.DecodeString(kdf.Salt)
	if err != nil {
		return nil, nil, secret.ErrSecret
	}
	key, err := secret.Derive(password, salt, kdf.Iterations)
	if err != nil {
		return nil, nil, err
	}
	opened, err := openConfig(c, key)
	return opened, key, err
}

func OpenWithKey(data, key []byte) (*api.Config, error) {
	c, problems := Parse(data)
	if len(problems) > 0 {
		return nil, &CheckError{problems}
	}
	return openConfig(c, key)
}

func openConfig(c *api.Config, key []byte) (*api.Config, error) {
	var check string
	_ = c.Section("check", &check)
	if !secret.CheckPassword(key, check) {
		return nil, secret.ErrSecret
	}
	var root object
	_ = json.Unmarshal(c.Raw, &root)
	open := func(v any) ([]byte, error) {
		s, ok := v.(string)
		if !ok || !strings.HasPrefix(s, "enc1:") {
			return nil, errors.New("В конфиге есть незашифрованный секрет.")
		}
		return secret.Open(key, s)
	}
	if len(c.Servers) > 0 {
		b, err := open(obj(root["server"])["key"])
		if err != nil {
			return nil, err
		}
		c.Servers[0].Key = b
	}
	paths := obj(root["paths"])
	if truth(paths["channel"]) {
		b, err := open(paths["channel"])
		if err != nil {
			return nil, err
		}
		if !json.Valid(b) {
			return nil, errors.New("Неверный JSON канала.")
		}
		c.Paths.Channel = b
	}
	c.Paths.Secrets = map[string]json.RawMessage{}
	for n, v := range obj(paths["secrets"]) {
		b, err := open(v)
		if err != nil {
			return nil, err
		}
		if !json.Valid(b) {
			return nil, errors.New("Неверный JSON секрета узла.")
		}
		c.Paths.Secrets[n] = b
	}
	return c, nil
}

func mask(c *api.Config, log api.Logger) {
	if log == nil {
		return
	}
	for _, s := range c.Servers {
		log.Secret(string(s.Key))
	}
	collect := func(b []byte) {
		var v any
		if json.Unmarshal(b, &v) == nil {
			collectSecrets(v, log)
		}
	}
	collect(c.Paths.Channel)
	for _, s := range c.Paths.Secrets {
		collect(s)
	}
}
func collectSecrets(v any, log api.Logger) {
	switch x := v.(type) {
	case map[string]any:
		for k, v := range x {
			switch k {
			case "uuid", "password", "private_key", "short_id", "public_key", "private_key_passphrase", "path":
				registerStrings(v, log)
			}
			collectSecrets(v, log)
		}
	case []any:
		for _, v := range x {
			collectSecrets(v, log)
		}
	}
}

func LoadFile(path, passwordFile string, log api.Logger) (*api.Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var password []byte
	if passwordFile != "" {
		password, err = os.ReadFile(passwordFile)
		if err != nil {
			return nil, err
		}
	}
	c, _, err := Open(data, strings.TrimRight(string(password), "\r\n"))
	if err == nil {
		mask(c, log)
	}
	return c, err
}

func registerStrings(v any, log api.Logger) {
	switch x := v.(type) {
	case string:
		log.Secret(x)
	case map[string]any:
		for _, v := range x {
			registerStrings(v, log)
		}
	case []any:
		for _, v := range x {
			registerStrings(v, log)
		}
	}
}
