package disk

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"remoteagents/internal/api"
)

// FoldersResult — итог принятия папок.
type FoldersResult struct {
	Accepted []string
	Waiting  []string
	Skipped  map[string]string // id → причина
}

// FoldersEnv — окружение AcceptFolders/Finish. Sleep подменяется в тестах.
type FoldersEnv struct {
	Home     string
	Client   *Client
	ServerID string
	SyncPort int // локальный порт проброса; 0 — адрес сервера не менять
	Folders  []Folder
	Base     string // каталог по умолчанию; пусто → ~/Disk
	Log      api.Logger
	// OfferWait — сколько ждать предложений сервера (по умолчанию 30 с).
	OfferWait time.Duration
	Sleep     func(ctx context.Context, d time.Duration) error
}

func (e *FoldersEnv) info(msg string, kv ...any) {
	if e.Log != nil {
		e.Log.Info(msg, kv...)
	}
}

func expandTilde(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") || strings.HasPrefix(p, `~\`) {
		h, _ := os.UserHomeDir()
		return filepath.Join(h, p[1:])
	}
	return p
}

func baseDir(base string) string {
	if base == "" {
		h, _ := os.UserHomeDir()
		return filepath.Join(h, "Disk")
	}
	return filepath.Clean(os.ExpandEnv(expandTilde(base)))
}

// SetServerDevice создаёт/правит устройство-сервер: адрес 127.0.0.1:syncPort, без автопринятия папок.
func SetServerDevice(ctx context.Context, c *Client, serverID string, syncPort int) error {
	addr := fmt.Sprintf("tcp://127.0.0.1:%d", syncPort)
	var devs []map[string]any
	if err := c.Do(ctx, "GET", "config/devices", nil, &devs); err != nil {
		return err
	}
	route := "config/devices/" + serverID
	for _, d := range devs {
		if d["deviceID"] != serverID {
			continue
		}
		patch := map[string]any{}
		if a, _ := d["addresses"].([]any); len(a) != 1 || a[0] != addr {
			patch["addresses"] = []string{addr}
		}
		if v, _ := d["autoAcceptFolders"].(bool); v {
			patch["autoAcceptFolders"] = false
		}
		if len(patch) == 0 {
			return nil
		}
		return c.Do(ctx, "PATCH", route, patch, nil)
	}
	var dev map[string]any
	if err := c.Do(ctx, "GET", "config/defaults/device", nil, &dev); err != nil {
		return err
	}
	dev["deviceID"], dev["name"], dev["addresses"], dev["autoAcceptFolders"] = serverID, "RemoteDisk Server", []string{addr}, false
	return c.Do(ctx, "PUT", route, dev, nil)
}

func hasFolder(existing []FolderCfg, id, serverID string) bool {
	for _, f := range existing {
		if f.ID() == id {
			return true
		}
		if f.Label() == id {
			devs, _ := f["devices"].([]any)
			for _, d := range devs {
				if m, _ := d.(map[string]any); m != nil && m["deviceID"] == serverID {
					return true
				}
			}
		}
	}
	return false
}

// isPlaceholderINI: desktop.ini — заглушка Проводника (owner=RemoteAgents.Disk.v2, placeholder=1).
func isPlaceholderINI(path string) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	s := string(b)
	if len(b) >= 2 && b[0] == 0xFF && b[1] == 0xFE { // UTF-16 LE
		u := make([]rune, 0, len(b)/2)
		for i := 2; i+1 < len(b); i += 2 {
			u = append(u, rune(b[i])|rune(b[i+1])<<8)
		}
		s = string(u)
	}
	s = strings.TrimPrefix(s, "\ufeff")
	section, vals := "", map[string]string{}
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || line[0] == ';' || line[0] == '#' {
			continue
		}
		if line[0] == '[' && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			continue
		}
		if k, v, ok := strings.Cut(line, "="); ok && section == "remoteagents" {
			vals[strings.ToLower(strings.TrimSpace(k))] = strings.TrimSpace(v)
		}
	}
	return vals["owner"] == "RemoteAgents.Disk.v2" && vals["placeholder"] == "1"
}

func hasLink(path string) bool {
	for p := path; ; {
		if fi, err := os.Lstat(p); err == nil && fi.Mode()&os.ModeSymlink != 0 {
			return true
		}
		parent := filepath.Dir(p)
		if parent == p {
			return false
		}
		p = parent
	}
}

// checkTarget: путь годится, если нет ссылок, это не файл и каталог пуст (или в нём только заглушка Проводника).
func checkTarget(path string) string {
	if hasLink(path) {
		return "ссылки в пути запрещены"
	}
	fi, err := os.Stat(path)
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		return "путь недоступен"
	}
	if !fi.IsDir() {
		return "путь занят файлом"
	}
	ents, err := os.ReadDir(path)
	if err != nil {
		return "путь недоступен"
	}
	if len(ents) == 0 {
		return ""
	}
	if len(ents) == 1 && strings.EqualFold(ents[0].Name(), "desktop.ini") && isPlaceholderINI(filepath.Join(path, ents[0].Name())) {
		return ""
	}
	return "папка не пуста"
}

// AcceptFolders принимает папки, предложенные сервером. Уже подключённые пропускает; не предложенные
// за OfferWait попадают в Waiting (повторить при следующем запуске).
func AcceptFolders(ctx context.Context, env FoldersEnv) (FoldersResult, error) {
	res := FoldersResult{Skipped: map[string]string{}}
	if len(env.Folders) == 0 {
		return res, nil
	}
	sleep := env.Sleep
	if sleep == nil {
		sleep = sleepCtx
	}
	wait := env.OfferWait
	if wait == 0 {
		wait = 30 * time.Second
	}
	c := env.Client
	existing, err := c.Folders(ctx)
	if err != nil {
		return res, err
	}
	var todo []Folder
	for _, f := range env.Folders {
		if hasFolder(existing, f.ID, env.ServerID) {
			res.Skipped[f.ID] = "уже подключена"
			continue
		}
		todo = append(todo, f)
	}
	if len(todo) == 0 {
		return res, nil
	}
	offers := map[string]string{}
	deadline := time.Now().Add(wait)
	for {
		pend, err := c.PendingFolders(ctx, env.ServerID)
		if err != nil {
			return res, err
		}
		for _, f := range todo {
			for _, p := range pend {
				if p.ID == f.ID || p.Label == f.ID {
					offers[f.ID] = p.ID
				}
			}
		}
		left := time.Until(deadline)
		if len(offers) == len(todo) || left <= 0 {
			break
		}
		if err := sleep(ctx, min(time.Second, left)); err != nil {
			return res, err
		}
	}
	myID := ""
	for _, f := range todo {
		actual := offers[f.ID]
		// человек мог принять папку в трее, пока ждали
		if existing, err = c.Folders(ctx); err != nil {
			return res, err
		}
		taken := hasFolder(existing, f.ID, env.ServerID)
		for _, x := range existing {
			if actual != "" && x.ID() == actual {
				taken = true
			}
		}
		if taken {
			res.Skipped[f.ID] = "уже подключена"
			continue
		}
		if actual == "" {
			res.Waiting = append(res.Waiting, f.ID)
			env.info("disk.folders.wait", "id", f.ID)
			continue
		}
		path := f.Path
		if path == "" {
			path = filepath.Join(baseDir(env.Base), f.ID)
		}
		path, _ = filepath.Abs(os.ExpandEnv(expandTilde(path)))
		if why := checkTarget(path); why != "" {
			res.Skipped[f.ID] = why
			env.info("disk.folders.skip", "id", f.ID, "why", why)
			continue
		}
		var cfg map[string]any
		if err := c.Do(ctx, "GET", "config/defaults/folder", nil, &cfg); err != nil {
			return res, err
		}
		if myID == "" {
			if myID, err = c.MyID(ctx); err != nil {
				return res, err
			}
		}
		cfg["id"], cfg["label"], cfg["path"], cfg["type"] = actual, f.ID, path, "sendreceive"
		cfg["fsWatcherEnabled"], cfg["fsWatcherDelayS"], cfg["maxConflicts"] = true, 2, -1
		cfg["devices"] = []map[string]any{{"deviceID": myID}, {"deviceID": env.ServerID}}
		cfg["versioning"] = map[string]any{"type": "staggered", "params": map[string]string{"maxAge": "2592000", "cleanInterval": "3600"}}
		if err := os.MkdirAll(path, 0o755); err != nil {
			return res, fmt.Errorf("не удалось подготовить папку Диска: %s", f.ID)
		}
		if err := WriteIgnore(path); err != nil {
			return res, fmt.Errorf("не удалось подготовить папку Диска: %s", f.ID)
		}
		if err := c.AddFolder(ctx, cfg); err != nil {
			return res, err
		}
		res.Accepted = append(res.Accepted, f.ID)
		env.info("disk.folders.accepted", "id", f.ID)
	}
	return res, nil
}

// Finish: устройство-сервер + папки; пишет join.json (done; либо folders, если сервер ещё не предложил часть папок).
func Finish(ctx context.Context, env FoldersEnv) (FoldersResult, error) {
	if _, err := env.Client.WaitReady(ctx, 40); err != nil {
		return FoldersResult{}, err
	}
	if env.SyncPort > 0 {
		if err := SetServerDevice(ctx, env.Client, env.ServerID, env.SyncPort); err != nil {
			return FoldersResult{}, err
		}
	}
	res, err := AcceptFolders(ctx, env)
	if err != nil {
		return res, err
	}
	stage := "done"
	if len(res.Waiting) > 0 {
		stage = "folders"
	}
	b, _ := json.Marshal(map[string]any{"stage": stage, "serverId": env.ServerID,
		"accepted": res.Accepted, "waiting": res.Waiting, "time": time.Now().Unix()})
	if err := writeAtomic(filepath.Join(env.Home, "join.json"), b); err != nil {
		return res, errors.New("не удалось сохранить данные Диска")
	}
	return res, nil
}

// NeedFinish: join.json есть и стадия не done (папки ещё не приняты).
func NeedFinish(home string) bool {
	p := readJSON(filepath.Join(home, "join.json"))
	if p == nil {
		return false
	}
	st, _ := p["stage"].(string)
	return st != "done"
}
