// Package disk: Диск (Syncthing) в v3. Здесь только разбор секции конфига disk.
package disk

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
)

// Folder — папка, которую нужно сразу скачать. Path пуст — каталог по умолчанию (Base/ID).
type Folder struct {
	ID   string `json:"id"`
	Path string `json:"path,omitempty"`
}

// Config — разобранный disk.* (+ верхний syncPort).
type Config struct {
	Home     string
	Base     string
	Folders  []Folder
	Enabled  *bool // nil — не задано (по умолчанию включено)
	SyncPort int   // 0 — не задан
}

// On сообщает, включено ли автоподключение (по умолчанию да).
func (c Config) On() bool { return c.Enabled == nil || *c.Enabled }

// DefaultHome — каталог Диска по умолчанию: Windows %LOCALAPPDATA%\RemoteDisk, иначе <home программы>/disk.
func DefaultHome(programHome string) string {
	if runtime.GOOS == "windows" {
		if b := os.Getenv("LOCALAPPDATA"); b != "" {
			return filepath.Join(b, "RemoteDisk")
		}
	}
	return filepath.Join(programHome, "disk")
}

const maxFolders = 256

var folderIDRe = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// ParseConfig разбирает disk.* (raw может быть пустым) и верхний syncPort (0 — нет).
// Папки: строка-ID или {id, path}; повторы пропускаются; недопустимое — ошибка.
func ParseConfig(raw json.RawMessage, topSyncPort int) (Config, error) {
	c := Config{SyncPort: topSyncPort}
	if topSyncPort != 0 && (topSyncPort < 1 || topSyncPort > 65535) {
		return c, fmt.Errorf("syncPort: порт должен быть 1..65535")
	}
	if runtime.GOOS == "windows" {
		c.Home = DefaultHome("")
	}
	if len(bytes.TrimSpace(raw)) == 0 || string(bytes.TrimSpace(raw)) == "null" {
		return c, nil
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return c, fmt.Errorf("disk: должен быть объектом")
	}
	str := func(key string, dst *string) error {
		v, ok := m[key]
		if !ok || string(v) == "null" {
			return nil
		}
		if err := json.Unmarshal(v, dst); err != nil {
			return fmt.Errorf("disk.%s: должна быть строка", key)
		}
		return nil
	}
	if err := str("home", &c.Home); err != nil {
		return c, err
	}
	if err := str("base", &c.Base); err != nil {
		return c, err
	}
	if v, ok := m["enabled"]; ok && string(v) != "null" {
		var b bool
		if err := json.Unmarshal(v, &b); err != nil {
			return c, fmt.Errorf("disk.enabled: должно быть true/false")
		}
		c.Enabled = &b
	}
	if v, ok := m["folders"]; ok && string(v) != "null" {
		var items []json.RawMessage
		if err := json.Unmarshal(v, &items); err != nil {
			return c, fmt.Errorf("disk.folders: должен быть список")
		}
		if len(items) > maxFolders {
			return c, fmt.Errorf("disk.folders: не больше %d папок", maxFolders)
		}
		seen := map[string]bool{}
		for i, it := range items {
			var f Folder
			if err := json.Unmarshal(it, &f.ID); err != nil {
				var o struct {
					ID   string  `json:"id"`
					Path *string `json:"path"`
				}
				if err := json.Unmarshal(it, &o); err != nil {
					return c, fmt.Errorf("disk.folders[%d]: строка или {id, path}", i)
				}
				f.ID = o.ID
				if o.Path != nil {
					f.Path = *o.Path
				}
			}
			if !folderIDRe.MatchString(f.ID) || f.ID == "." || f.ID == ".." {
				return c, fmt.Errorf("disk.folders[%d]: недопустимый ID папки", i)
			}
			if seen[f.ID] {
				continue
			}
			seen[f.ID] = true
			c.Folders = append(c.Folders, f)
		}
	}
	return c, nil
}
