package config

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"

	"remoteagents/internal/api"
	"remoteagents/internal/deps"
)

// Settings is the read-only legacy settings.py view. Path building belongs to channel.
type Settings struct {
	Config                         *api.Config
	Values                         map[string]any
	Profile                        map[string]any
	Server, Login, Key, KnownHosts string
	Port                           int
	SSH, Singbox                   string
	Outbounds                      []map[string]any
}

func readJSON(path string, dst any) error {
	data, err := os.ReadFile(path)
	if err == nil {
		err = json.Unmarshal([]byte(strings.TrimPrefix(string(data), "\ufeff")), dst)
	}
	if err != nil {
		return errors.New("не прочитать JSON " + filepath.Base(path))
	}
	return nil
}

// LegacyView maps the applied config to the same keys as v2config.legacy_view.
func LegacyView(p api.Paths) (map[string]any, error) {
	active, _, _, _ := locations(p)
	data, err := os.ReadFile(active)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNoConfig
	}
	if err != nil {
		return nil, err
	}
	c, problems := Parse(data)
	if len(problems) > 0 {
		return nil, &CheckError{problems}
	}
	var cfg object
	_ = json.Unmarshal(c.Raw, &cfg)
	_, _, v2, _ := locations(p)
	paths := obj(cfg["paths"])
	t := object{"profilePath": filepath.Join(v2, "ssh-profile.json"), "cacheRoot": v2}
	if c.VPNOnly {
		t = object{}
	}
	if truth(paths["channel"]) {
		t["channelPath"] = filepath.Join(v2, "channel.json")
	}
	for _, k := range []string{"entries", "relays", "cdn", "hops", "wsEntries"} {
		var out []any
		items, _ := paths[k].([]any)
		for _, x := range items {
			if s, ok := x.(string); ok {
				out = append(out, object{"name": s})
			} else if _, ok := x.(map[string]any); ok {
				out = append(out, x)
			}
		}
		t[k] = out
	}
	if d := obj(cfg["disk"]); truth(d["syncPort"]) {
		t["syncPort"] = d["syncPort"]
	} else if truth(cfg["syncPort"]) {
		t["syncPort"] = cfg["syncPort"]
	}
	out := object{}
	if !c.VPNOnly {
		out["transport"] = t
	}
	for _, k := range []string{"lan", "happier", "forwards", "lanProxy", "tun"} {
		if v, ok := cfg[k]; ok {
			out[k] = v
		}
	}
	if v, ok := cfg["vpn"].(map[string]any); ok {
		vpn := object{}
		for k, x := range v {
			if k != "mode" {
				vpn[k] = x
			}
		}
		out["vpn"] = vpn
	}
	if d := obj(cfg["disk"]); truth(d["home"]) {
		out["disk"] = object{"home": d["home"]}
	}
	return out, nil
}

// LoadSettings keeps v2's shallow lab-over-installed merge, without network polling.
// Callers reload on app.start / net.changed / channel.down; no LOAD_GAP timer is needed.
func LoadSettings(p api.Paths, installed string, bins *deps.Bundle, log api.Logger) (*Settings, error) {
	cfg, err := LegacyView(p)
	if err != nil && !errors.Is(err, ErrNoConfig) {
		return nil, err
	}
	if cfg == nil {
		cfg = object{}
		path := filepath.Join(installed, "config.json")
		if exists(path) {
			if err := readJSON(path, &cfg); err != nil {
				return nil, err
			}
		}
	}
	lab := filepath.Join(p.Home, "config.json")
	if exists(lab) {
		var over object
		if err := readJSON(lab, &over); err != nil {
			return nil, err
		}
		for k, v := range over {
			a, aok := cfg[k].(map[string]any)
			b, bok := v.(map[string]any)
			if aok && bok {
				merged := object{}
				for k, v := range a {
					merged[k] = v
				}
				for k, v := range b {
					merged[k] = v
				}
				cfg[k] = merged
			} else {
				cfg[k] = v
			}
		}
		if log != nil {
			log.Info("lab.config", "file", lab)
		}
	}
	c, _, err := Load(p, log)
	if err != nil && !errors.Is(err, ErrNoConfig) {
		return nil, err
	}
	// Apply lab overrides to the typed runtime view too; keep unlocked secret bytes.
	runtimeRoot := object{}
	if c != nil {
		_ = json.Unmarshal(c.Raw, &runtimeRoot)
	}
	for k, v := range cfg {
		if k != "vpn" {
			runtimeRoot[k] = v
		}
	}
	if vpn, ok := cfg["vpn"].(map[string]any); ok {
		merged := obj(runtimeRoot["vpn"])
		for k, v := range vpn {
			merged[k] = v
		}
		runtimeRoot["vpn"] = merged
	}
	tcfg := obj(cfg["transport"])
	if len(tcfg) > 0 {
		paths := obj(runtimeRoot["paths"])
		for _, k := range []string{"entries", "relays", "hops", "cdn", "wsEntries"} {
			if v, ok := tcfg[k]; ok {
				paths[k] = v
			}
		}
		runtimeRoot["paths"] = paths
	}
	normalized := normalize(runtimeRoot)
	normalized.Raw = raw(runtimeRoot)
	if c != nil {
		normalized.Servers = c.Servers
		normalized.Paths.Secrets = c.Paths.Secrets
		normalized.Paths.Channel = c.Paths.Channel
		normalized.VPNOnly = c.VPNOnly
	}
	c = normalized
	s := &Settings{Config: c, Values: cfg, Port: 22}
	if c.VPNOnly {
		return s, nil
	}
	t := obj(cfg["transport"])
	profile := str(t["profilePath"])
	if profile == "" {
		return nil, errors.New("нет transport.profilePath: установленная RemoteAgents не настроена")
	}
	if err := readJSON(profile, &s.Profile); err != nil {
		return nil, err
	}
	for _, k := range []string{"serverAddress", "login", "keyPath", "knownHostsPath"} {
		if !truth(s.Profile[k]) {
			return nil, errors.New("в SSH-профиле нет поля " + k)
		}
	}
	s.Server, s.Login, s.Key, s.KnownHosts = str(s.Profile["serverAddress"]), str(s.Profile["login"]), str(s.Profile["keyPath"]), str(s.Profile["knownHostsPath"])
	args, _ := s.Profile["arguments"].([]any)
	for i, v := range args {
		if str(v) == "-p" && i+1 < len(args) {
			if port := integer(args[i+1], 22); port != 0 {
				s.Port = port
			}
			break
		}
	}
	if channel := str(t["channelPath"]); channel != "" {
		var ch struct{ Outbounds []map[string]any }
		if err := readJSON(channel, &ch); err == nil {
			s.Outbounds = ch.Outbounds
			if log != nil {
				var value any
				decode(ch.Outbounds, &value)
				collectSecrets(value, log)
			}
		} else if log != nil {
			log.Warn("channel.missing", "why", "без channel пути relay/hop недоступны, узлы входа работают")
		}
	}
	if len(c.Servers) == 0 {
		key, err := os.ReadFile(s.Key)
		if err != nil {
			return nil, err
		}
		hostKeys := KnownHostKeys(s.KnownHosts, s.Server, s.Port)
		if len(hostKeys) == 0 {
			return nil, errors.New("в known_hosts нет ключа сервера")
		}
		c.Servers = []api.Server{{Host: s.Server, Port: s.Port, User: s.Login, Key: key, HostKey: hostKeys[0]}}
	}
	if s.Outbounds != nil {
		c.Paths.Channel = raw(object{"outbounds": s.Outbounds})
	}
	if c.Paths.Secrets == nil {
		c.Paths.Secrets = map[string]json.RawMessage{}
	}
	if cache := str(t["cacheRoot"]); cache != "" {
		for _, entry := range c.Paths.Entries {
			if !nameRE.MatchString(entry.Name) {
				continue
			}
			var v any
			if err := readJSON(filepath.Join(cache, "secrets", "entries", entry.Name+".json"), &v); err == nil {
				c.Paths.Secrets[entry.Name] = raw(v)
			}
		}
	}
	if log != nil {
		mask(c, log)
	}
	s.SSH, err = findBinary("ssh", installed, s.Profile, cfg, bins)
	if err != nil {
		return nil, err
	}
	s.Singbox, err = findBinary("sing-box", installed, s.Profile, cfg, bins)
	if err != nil {
		return nil, err
	}
	return s, nil
}

func findBinary(name, installed string, profile, cfg object, bins *deps.Bundle) (string, error) {
	rel := name
	if runtime.GOOS == "windows" {
		rel += ".exe"
	}
	if name == "ssh" && runtime.GOOS == "windows" {
		rel = "openssh/ssh.exe"
	}
	if bins != nil && bins.Strict() {
		found := bins.Find(rel)
		if name == "ssh" && runtime.GOOS == "windows" && bins.Find("openssh/libcrypto.dll") == "" {
			return "", errors.New("вшитый ssh недоступен: нет libcrypto.dll")
		}
		if found == "" {
			return "", errors.New("вшитый " + name + " недоступен: " + bins.Why(rel))
		}
		return found, nil
	}
	candidates := []string{str(obj(cfg["transport"])["singBoxPath"]), filepath.Join(installed, "transport-bin", filepath.FromSlash(rel))}
	if name == "ssh" {
		candidates[0] = str(profile["sshExecutable"])
	}
	exe := name
	if runtime.GOOS == "windows" {
		exe += ".exe"
	}
	matches, _ := filepath.Glob(filepath.Join(installed, "bundle", "*", "transport", exe))
	sort.Sort(sort.Reverse(sort.StringSlice(matches)))
	candidates = append(candidates, matches...)
	if name == "ssh" && runtime.GOOS == "windows" {
		root := os.Getenv("SystemRoot")
		if root == "" {
			root = `C:\Windows`
		}
		candidates = append(candidates, filepath.Join(root, "System32", "OpenSSH", "ssh.exe"))
	}
	for _, p := range candidates {
		if st, err := os.Stat(p); p != "" && err == nil && st.Mode().IsRegular() {
			return p, nil
		}
	}
	if found, err := exec.LookPath(name); err == nil {
		return found, nil
	}
	return "", errors.New(name + " не найден")
}

// KnownHostKeys accepts hashed names, wildcards and negations, as settings.py does.
func KnownHostKeys(path, host string, port int) []string {
	name := host
	if port != 22 {
		name = "[" + host + "]:" + strconv.Itoa(port)
	}
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 4*1024*1024))
	if err != nil {
		return nil
	}
	lines := strings.Split(strings.ReplaceAll(strings.TrimPrefix(string(data), "\ufeff"), "\r", ""), "\n")
	if len(lines) > 20000 {
		lines = lines[:20000]
	}
	var keys []string
	seen := map[string]bool{}
	for _, line := range lines {
		parts := strings.Fields(line)
		if len(parts) < 3 || strings.HasPrefix(parts[0], "#") || strings.HasPrefix(parts[0], "@") {
			continue
		}
		key := parts[1] + " " + parts[2]
		if (strings.HasPrefix(parts[1], "ssh-") || strings.HasPrefix(parts[1], "ecdsa-")) && hostMatch(parts[0], name) && !seen[key] {
			keys = append(keys, key)
			seen[key] = true
		}
	}
	return keys
}
func hostMatch(field, name string) bool {
	if strings.HasPrefix(field, "|1|") {
		parts := strings.Split(field, "|")
		if len(parts) < 4 {
			return false
		}
		salt, err := base64.StdEncoding.DecodeString(parts[2])
		if err != nil {
			return false
		}
		mac := hmac.New(sha1.New, salt)
		mac.Write([]byte(name))
		return hmac.Equal([]byte(base64.StdEncoding.EncodeToString(mac.Sum(nil))), []byte(parts[3]))
	}
	matched := false
	for _, pattern := range strings.Split(field, ",") {
		neg := strings.HasPrefix(pattern, "!")
		pattern = strings.TrimLeft(pattern, "!")
		// fnmatch-style * and ? also match dots and slashes in host fields.
		rx := strings.ReplaceAll(strings.ReplaceAll(regexp.QuoteMeta(strings.ToLower(pattern)), `\*`, ".*"), `\?`, ".")
		ok, _ := regexp.MatchString("^"+rx+"$", strings.ToLower(name))
		if ok {
			if neg {
				return false
			}
			matched = true
		}
	}
	return matched
}
