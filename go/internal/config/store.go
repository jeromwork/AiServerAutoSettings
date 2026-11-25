package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"remoteagents/internal/api"
)

func locations(p api.Paths) (active, prev, v2, v2prev string) {
	return filepath.Join(p.Config, "active.json"), filepath.Join(p.Config, "prev.json"), filepath.Join(p.Home, "private", "v2"), filepath.Join(p.Home, "private", "v2.prev")
}
func exists(path string) bool { _, err := os.Stat(path); return err == nil }
func write(path string, data []byte, private bool, log api.Logger) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	mode := os.FileMode(0644)
	if private {
		mode = 0600
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	if private {
		if err := os.Chmod(tmp, mode); err != nil {
			os.Remove(tmp)
			return err
		}
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	if private {
		protect(path, log)
	}
	return nil
}
func writeJSON(path string, v any, private bool, log api.Logger) error {
	b, err := json.MarshalIndent(v, "", " ")
	if err != nil {
		return err
	}
	return write(path, b, private, log)
}

// transaction remembers only the moves v2 needs; no generation IDs or pending deadlines.
type transaction struct{ undo []func() }

func (t *transaction) move(from, to string) error {
	if err := os.Rename(from, to); err != nil {
		return err
	}
	t.undo = append(t.undo, func() { _ = os.Rename(to, from) })
	return nil
}
func (t *transaction) rollback() {
	for i := len(t.undo) - 1; i >= 0; i-- {
		t.undo[i]()
	}
}

func Apply(p api.Paths, data []byte, password string, log api.Logger) (string, error) {
	c, _, err := Open(data, password)
	if err != nil {
		return "", err
	}
	mask(c, log)
	active, prev, v2, v2prev := locations(p)
	base := v2 + ".new"
	for _, f := range []string{base, prev + ".old", v2prev + ".old"} {
		if err := os.RemoveAll(f); err != nil {
			return "", err
		}
	}
	t := &transaction{}
	defer func() {
		if err != nil {
			t.rollback()
			_ = os.RemoveAll(base)
			_ = os.Remove(active + ".new")
		}
	}()
	stage := func() error {
		if err := os.MkdirAll(base, 0700); err != nil {
			return err
		}
		if len(c.Servers) > 0 {
			s := c.Servers[0]
			key := strings.ReplaceAll(string(s.Key), "\r\n", "\n")
			if !strings.HasSuffix(key, "\n") {
				key += "\n"
			}
			if err := write(filepath.Join(base, "id_key"), []byte(key), true, log); err != nil {
				return err
			}
			host := s.Host
			if s.Port != 22 {
				host = "[" + host + "]:" + strconv.Itoa(s.Port)
			}
			if err := write(filepath.Join(base, "known_hosts"), []byte(host+" "+strings.TrimSpace(s.HostKey)+"\n"), false, log); err != nil {
				return err
			}
			profile := object{"serverAddress": s.Host, "login": s.User, "keyPath": filepath.Join(v2, "id_key"), "knownHostsPath": filepath.Join(v2, "known_hosts"), "arguments": []string{"-p", strconv.Itoa(s.Port)}}
			if err := writeJSON(filepath.Join(base, "ssh-profile.json"), profile, false, log); err != nil {
				return err
			}
		}
		if c.Paths.Channel != nil {
			if err := write(filepath.Join(base, "channel.json"), c.Paths.Channel, true, log); err != nil {
				return err
			}
		}
		for n, b := range c.Paths.Secrets {
			if err := write(filepath.Join(base, "secrets", "entries", n+".json"), b, true, log); err != nil {
				return err
			}
		}
		text := string(data)
		if !strings.HasSuffix(text, "\n") {
			text += "\n"
		}
		if err := write(active+".new", []byte(text), true, log); err != nil {
			return err
		}
		if exists(prev) && exists(v2prev) {
			if err := t.move(prev, prev+".old"); err != nil {
				return err
			}
			if err := t.move(v2prev, v2prev+".old"); err != nil {
				return err
			}
		} else {
			if err := os.RemoveAll(prev); err != nil {
				return err
			}
			if err := os.RemoveAll(v2prev); err != nil {
				return err
			}
		}
		if exists(v2) {
			if err := t.move(v2, v2prev); err != nil {
				return err
			}
		}
		if err := t.move(base, v2); err != nil {
			return err
		}
		if exists(active) {
			if err := t.move(active, prev); err != nil {
				return err
			}
		}
		if err := t.move(active+".new", active); err != nil {
			return err
		}
		for name, val := range map[string]any{"vpn.json": object{"mode": c.VPN.Mode}, "control.json": object{"enabled": c.Control.Enabled}} {
			f := filepath.Join(p.State, name)
			old, readErr := os.ReadFile(f)
			if readErr == nil {
				t.undo = append(t.undo, func() { _ = write(f, old, false, log) })
			} else if errors.Is(readErr, os.ErrNotExist) {
				t.undo = append(t.undo, func() { _ = os.Remove(f) })
			} else {
				return readErr
			}
			if err := writeJSON(f, val, false, log); err != nil {
				return err
			}
		}
		return nil
	}
	err = stage()
	if err != nil {
		return "", errors.New("Не удалось применить конфиг.")
	}
	_ = os.RemoveAll(prev + ".old")
	_ = os.RemoveAll(v2prev + ".old")
	return active, nil
}

func Revert(p api.Paths, log api.Logger) error {
	active, prev, v2, v2prev := locations(p)
	old := v2 + ".old"
	_ = os.RemoveAll(old)
	t := &transaction{}
	if exists(prev) && exists(v2prev) {
		if exists(v2) {
			if err := t.move(v2, old); err != nil {
				return err
			}
		}
		if err := t.move(v2prev, v2); err != nil {
			t.rollback()
			return err
		}
		if err := os.Rename(prev, active); err != nil {
			t.rollback()
			return err
		}
	} else {
		for _, f := range []string{active, prev, v2, v2prev} {
			if err := os.RemoveAll(f); err != nil {
				return err
			}
		}
	}
	return os.RemoveAll(old)
}

// Load reads the encrypted original plus the files already unlocked by Apply.
func Load(p api.Paths, log api.Logger) (*api.Config, string, error) {
	active, _, v2, _ := locations(p)
	b, err := os.ReadFile(active)
	if errors.Is(err, os.ErrNotExist) {
		return nil, "", ErrNoConfig
	}
	if err != nil {
		return nil, "", err
	}
	c, pr := Parse(b)
	if len(pr) > 0 {
		return nil, "", &CheckError{pr}
	}
	if len(c.Servers) > 0 {
		c.Servers[0].Key, err = os.ReadFile(filepath.Join(v2, "id_key"))
		if err != nil {
			return nil, "", err
		}
	}
	var root object
	_ = json.Unmarshal(c.Raw, &root)
	paths := obj(root["paths"])
	if truth(paths["channel"]) {
		c.Paths.Channel, err = os.ReadFile(filepath.Join(v2, "channel.json"))
		if err != nil {
			return nil, "", err
		}
		if !json.Valid(c.Paths.Channel) {
			return nil, "", errors.New("Неверный JSON канала.")
		}
	}
	c.Paths.Secrets = map[string]json.RawMessage{}
	for n := range obj(paths["secrets"]) {
		b, err := os.ReadFile(filepath.Join(v2, "secrets", "entries", n+".json"))
		if err != nil {
			return nil, "", err
		}
		if !json.Valid(b) {
			return nil, "", errors.New("Неверный JSON секрета узла.")
		}
		c.Paths.Secrets[n] = b
	}
	mask(c, log)
	return c, active, nil
}

type ConfigStatus struct {
	Has    bool   `json:"has"`
	Name   string `json:"name"`
	Server string `json:"server"`
	Time   string `json:"time"`
}

func Status(p api.Paths) ConfigStatus {
	active, _, _, _ := locations(p)
	b, err := os.ReadFile(active)
	if err != nil {
		return ConfigStatus{}
	}
	var root object
	if json.Unmarshal([]byte(strings.TrimPrefix(string(b), "\ufeff")), &root) != nil || root["format"] != "remoteagents-2" {
		return ConfigStatus{}
	}
	s := ConfigStatus{Has: true, Name: str(root["name"]), Server: str(obj(root["server"])["host"])}
	if info, err := os.Stat(active); err == nil {
		s.Time = info.ModTime().In(time.Local).Format("2006-01-02 15:04")
	}
	return s
}
