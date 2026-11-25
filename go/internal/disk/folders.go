package disk

import (
	"context"
	"encoding/binary"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf16"
)

type folder struct {
	ID   string `json:"id"`
	Path string `json:"path,omitempty"`
}

var folderPattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

func (d *Disk) wanted() []folder {
	var result []folder
	seen := map[string]bool{}
	for i, raw := range d.cfg.Folders {
		if i >= 256 {
			break
		}
		var f folder
		if readBytes(raw, &f.ID) != nil {
			if readBytes(raw, &f) != nil {
				d.log("join-folder-skip", "reason", "неверная папка")
				continue
			}
		}
		if !folderPattern.MatchString(f.ID) || f.ID == "." || f.ID == ".." {
			d.log("join-folder-skip", "reason", "недопустимый ID папки")
			continue
		}
		if !seen[f.ID] {
			result = append(result, f)
			seen[f.ID] = true
		}
	}
	return result
}
func hasFolder(folders []map[string]any, id, serverID string) bool {
	for _, f := range folders {
		if f["id"] == id {
			return true
		}
		if f["label"] == id {
			devices, _ := f["devices"].([]any)
			for _, v := range devices {
				device, _ := v.(map[string]any)
				if device["deviceID"] == serverID {
					return true
				}
			}
		}
	}
	return false
}
func offeredID(pending map[string]map[string]any, id, serverID string) string {
	for actual, details := range pending {
		offeredBy, _ := details["offeredBy"].(map[string]any)
		offered, ok := offeredBy[serverID].(map[string]any)
		if ok && (actual == id || offered["label"] == id) {
			return actual
		}
	}
	return ""
}
func placeholder(path string) bool {
	b, e := os.ReadFile(path)
	if e != nil {
		return false
	}
	text := strings.TrimPrefix(string(b), "\ufeff")
	if len(b) >= 2 && (binary.LittleEndian.Uint16(b[:2]) == 0xfeff || binary.BigEndian.Uint16(b[:2]) == 0xfeff) {
		var order binary.ByteOrder = binary.LittleEndian
		if b[0] == 0xfe {
			order = binary.BigEndian
		}
		units := make([]uint16, 0, (len(b)-2)/2)
		for i := 2; i+1 < len(b); i += 2 {
			units = append(units, order.Uint16(b[i:i+2]))
		}
		text = string(utf16.Decode(units))
	}
	section := ""
	values := map[string]string{}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, ";") || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			continue
		}
		if section == "remoteagents" {
			k, v, ok := strings.Cut(line, "=")
			if ok {
				values[strings.ToLower(strings.TrimSpace(k))] = strings.TrimSpace(v)
			}
		}
	}
	return values["owner"] == "RemoteAgents.Disk.v2" && values["placeholder"] == "1"
}
func folderPath(path string) (string, error) {
	path, e := filepath.Abs(expand(path))
	if e != nil {
		return "", e
	}
	for part := path; ; part = filepath.Dir(part) {
		st, e := os.Lstat(part)
		if e == nil && (st.Mode()&os.ModeSymlink != 0 || isJunction(part)) {
			return "", errors.New("ссылки в пути запрещены")
		}
		if part == filepath.Dir(part) {
			break
		}
	}
	if st, e := os.Stat(path); e == nil {
		if !st.IsDir() {
			return "", errors.New("путь занят файлом")
		}
		entries, e := os.ReadDir(path)
		if e != nil {
			return "", e
		}
		if len(entries) > 0 && (len(entries) != 1 || !strings.EqualFold(entries[0].Name(), "desktop.ini") || !placeholder(filepath.Join(path, entries[0].Name()))) {
			return "", errors.New("папка не пуста")
		}
	} else if !os.IsNotExist(e) {
		return "", e
	}
	return path, nil
}

// finish is called on API readiness and Syncthing events; missing offers remain pending.
func (d *Disk) finish(ctx context.Context, r *rest, s server) error {
	path := filepath.Join(d.home, "join.json")
	var p progress
	if !exists(path) || readJSON(path, &p) && p.Stage == "done" {
		return nil
	}
	if e := r.setServer(ctx, s.DeviceID, d.syncPort()); e != nil {
		return e
	}
	var folders []map[string]any
	if e := r.get(ctx, "config/folders", &folders); e != nil {
		return e
	}
	var pending map[string]map[string]any
	if e := r.get(ctx, "cluster/pending/folders?device="+url.QueryEscape(s.DeviceID), &pending); e != nil {
		return e
	}
	result := progress{Stage: "done", ServerID: s.DeviceID, Time: time.Now().Unix()}
	var myID string
	for _, f := range d.wanted() {
		actual := offeredID(pending, f.ID, s.DeviceID)
		// Re-read: a person may have accepted the folder in the tray.
		if e := r.get(ctx, "config/folders", &folders); e != nil {
			return e
		}
		if hasFolder(folders, f.ID, s.DeviceID) || actual != "" && hasFolder(folders, actual, s.DeviceID) {
			continue
		}
		if actual == "" {
			result.Waiting = append(result.Waiting, f.ID)
			result.Stage = "folders"
			continue
		}
		path := f.Path
		if path == "" {
			path = filepath.Join(d.base, f.ID)
		}
		path, e := folderPath(path)
		if e != nil {
			d.log("join-folder-skip", "id", f.ID, "reason", e.Error())
			continue
		}
		var config map[string]any
		if e = r.get(ctx, "config/defaults/folder", &config); e != nil {
			return e
		}
		if myID == "" {
			var status struct {
				MyID string `json:"myID"`
			}
			if e = r.get(ctx, "system/status", &status); e != nil {
				return e
			}
			myID = status.MyID
			if myID == "" {
				return errors.New("Диск не сообщил ID устройства.")
			}
		}
		for k, v := range map[string]any{"id": actual, "label": f.ID, "path": path, "type": "sendreceive", "fsWatcherEnabled": true, "fsWatcherDelayS": 2, "maxConflicts": -1, "devices": []map[string]string{{"deviceID": myID}, {"deviceID": s.DeviceID}}, "versioning": map[string]any{"type": "staggered", "params": map[string]string{"maxAge": "2592000", "cleanInterval": "3600"}}} {
			config[k] = v
		}
		if e = os.MkdirAll(path, 0700); e != nil {
			return errors.New("Не удалось подготовить папку Диска.")
		}
		if e = writeFile(filepath.Join(path, ".stignore-remoteagents"), []byte(ignoreRules)); e != nil {
			return e
		}
		if e = writeFile(filepath.Join(path, ".stignore"), []byte("#include .stignore-remoteagents\n")); e != nil {
			return e
		}
		if e = r.put(ctx, "POST", "config/folders", config); e != nil {
			return e
		}
		result.Accepted = append(result.Accepted, f.ID)
		d.log("join-folder-accepted", "id", f.ID)
	}
	return writeJSON(filepath.Join(d.home, "join.json"), result)
}
