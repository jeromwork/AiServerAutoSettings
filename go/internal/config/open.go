package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"strings"

	"remoteagents/internal/api"
	"remoteagents/internal/secret"
)

// Check validates and decrypts without side effects (api: Check).
func Check(data []byte, password string) (*api.Config, error) {
	c, key, err := Open(data, password)
	clear(key)
	return c, err
}

// Open = Parse + password check + decryption. The second result is the derived key (64 bytes);
// the caller clears it.
func Open(data []byte, password string) (*api.Config, []byte, error) {
	c, pr := Parse(data)
	if len(pr) > 0 {
		return nil, nil, &CheckError{Problems: pr}
	}
	root, _ := decodeJSON(trimBOM(data))
	key, err := kdfOf(root, password)
	if err != nil {
		return nil, nil, &CheckError{Problems: []Problem{{Stage: "password", Code: "kdf", Field: "kdf", Msg: "invalid password parameters"}}}
	}
	if err := decrypt(c, root, key); err != nil {
		clear(key)
		return nil, nil, err
	}
	return c, key, nil
}

// OpenWithKey decrypts with an already derived key (autostart: key saved by SaveKey).
func OpenWithKey(data []byte, key []byte) (*api.Config, error) {
	c, pr := Parse(data)
	if len(pr) > 0 {
		return nil, &CheckError{Problems: pr}
	}
	root, _ := decodeJSON(trimBOM(data))
	if err := decrypt(c, root, key); err != nil {
		return nil, err
	}
	return c, nil
}

func fail(stage, code, field, msg string) error {
	return &CheckError{Problems: []Problem{{Stage: stage, Code: code, Field: field, Msg: msg}}}
}

func decrypt(c *api.Config, root obj, key []byte) error {
	if len(key) != 64 || !secret.CheckPassword(key, strOf(root["check"])) {
		return fail("password", "password", "check", "invalid password")
	}
	srv, _ := root["server"].(obj)
	pk, err := secret.Open(key, strOf(srv["key"]))
	if err != nil {
		return fail("decrypt", "decrypt", "server.key", "cannot decrypt")
	}
	c.Servers[0].Key = pk
	paths, _ := root["paths"].(obj)
	if ch := strOf(paths["channel"]); ch != "" {
		plain, err := secret.Open(key, ch)
		if err != nil {
			return fail("decrypt", "decrypt", "paths.channel", "cannot decrypt")
		}
		if !json.Valid(plain) {
			return fail("decrypt", "json", "paths.channel", "decrypted channel is not JSON")
		}
		c.Paths.Channel = plain
	}
	s, _ := paths["secrets"].(obj)
	for _, n := range sortedKeys(s) {
		plain, err := secret.Open(key, strOf(s[n]))
		if err != nil {
			return fail("decrypt", "decrypt", "paths.secrets."+n, "cannot decrypt")
		}
		if !json.Valid(plain) {
			return fail("decrypt", "json", "paths.secrets."+n, "decrypted secret is not JSON")
		}
		c.Paths.Secrets[n] = plain
	}
	return nil
}

// register hands every decrypted value to the journal masker (Constitution: secrets never reach logs).
func register(c *api.Config, log api.Logger) {
	if c == nil || log == nil {
		return
	}
	for _, s := range c.Servers {
		if len(s.Key) > 0 {
			log.Secret(string(s.Key))
		}
	}
	if len(c.Paths.Channel) > 0 {
		log.Secret(string(c.Paths.Channel))
		registerJSON(c.Paths.Channel, log)
	}
	for _, v := range c.Paths.Secrets {
		if len(v) > 0 {
			log.Secret(string(v))
			registerJSON(v, log)
		}
	}
	if len(c.Unknown) > 0 {
		log.Warn("config.unknown-fields", "names", strings.Join(c.Unknown, ","))
	}
}

func registerJSON(b []byte, log api.Logger) {
	var v any
	if json.Unmarshal(b, &v) == nil {
		walk(v, log)
	}
}

// PlainKeys — поля, значения которых не секрет: имена путей/узлов, теги и типы. Их маскировать нельзя:
// иначе имена путей в журнале и на странице превращаются в `***`.
var PlainKeys = map[string]bool{
	"tag": true, "type": true, "name": true, "outbound": true, "outbounds": true, "inbound": true, "detour": true,
	"default": true, "network": true, "flow": true, "level": true, "listen": true, "security": true,
	"packet_encoding": true, "method": true, "kind": true, "kinds": true, "label": true, "final": true,
}

func walk(v any, log api.Logger) { walkKey(v, "", log) }

func walkKey(v any, key string, log api.Logger) {
	switch t := v.(type) {
	case string:
		if !PlainKeys[key] {
			log.Secret(t)
		}
	case []any:
		for _, x := range t {
			walkKey(x, key, log)
		}
	case map[string]any:
		for k, x := range t {
			walkKey(x, k, log)
		}
	}
}

// LoadFile: dev/bench — file + password file, no generations.
func LoadFile(path, passwordFile string, log api.Logger) (*api.Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("config: read: cannot read config file")
	}
	pw, err := os.ReadFile(passwordFile)
	if err != nil {
		return nil, errors.New("config: read: cannot read password file")
	}
	pass := string(bytes.TrimRight(pw, "\r\n"))
	if log != nil {
		log.Secret(pass)
	}
	c, key, err := Open(data, pass)
	clear(key)
	if err != nil {
		return nil, err
	}
	register(c, log)
	return c, nil
}
