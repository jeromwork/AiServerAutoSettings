package disk

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// State — состояние Диска для страницы и трея.
type State string

const (
	StateAbsent  State = "absent"  // Диск не настроен/выключен/нет syncthing
	StateWait    State = "wait"    // ждёт канал, паузу после падения или освобождения home
	StateJoining State = "joining" // идёт подключение ПК к серверу
	StateRunning State = "running"
	StateError   State = "error"
)

var stateText = map[State]string{
	StateAbsent: "не установлен", StateWait: "ждёт канал", StateJoining: "подключается",
	StateRunning: "работает", StateError: "ошибка",
}

// Text — русская подпись состояния.
func (s State) Text() string { return stateText[s] }

// Snapshot — то, что публикуется событием "disk" и идёт в /state.
type Snapshot struct {
	State State  `json:"state"`
	Why   string `json:"why,omitempty"`
	Text  string `json:"text"`
}

func (s Snapshot) Map() map[string]any {
	m := map[string]any{"state": string(s.State), "text": s.Text}
	if s.Why != "" {
		m["why"] = s.Why
	}
	return m
}

var pathRe = regexp.MustCompile(`[A-Za-z]:[\\/][^\s"']*|(?:\\\\|/)[^\s"']+|"[^"]*"|'[^']*'`)

// safeLine — строка вывода Syncthing для журнала: только WARN/ERR, без путей и имён файлов, до 120 знаков.
func safeLine(text string) (string, bool) {
	if !regexp.MustCompile(`\b(WARN|WARNING|ERR|ERROR)\b`).MatchString(text) {
		return "", false
	}
	s := pathRe.ReplaceAllString(text, "<..>")
	if r := []rune(s); len(r) > 120 {
		s = string(r[:120])
	}
	return s, true
}

func readJSON(path string) map[string]any {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var m map[string]any
	if json.Unmarshal([]byte(strings.TrimPrefix(string(b), "\uFEFF")), &m) != nil {
		return nil
	}
	return m
}

func port(v any) int {
	f, ok := v.(float64)
	if !ok || f < 1 || f > 65535 || f != float64(int(f)) {
		return 0
	}
	return int(f)
}

// needJoin — нужна ли регистрация ПК на сервере: join.json в стадии identity/server, либо Диска ещё нет совсем.
// Диск старой Программы (config.xml без join.json) не присваиваем.
func needJoin(home string) bool {
	if p := readJSON(filepath.Join(home, "join.json")); p != nil {
		st, _ := p["stage"].(string)
		return st == "identity" || st == "server"
	}
	if _, err := os.Stat(filepath.Join(home, "state", "config.xml")); err == nil {
		return false
	}
	_, err := os.Stat(filepath.Join(home, "server.json"))
	return err != nil
}

// serverSyncPort — серверный порт синхронизации: вход sync (override_port) из канала конфига, иначе server.json.
func serverSyncPort(channel json.RawMessage, home string) int {
	if len(channel) > 0 {
		var ch struct {
			Inbounds []map[string]any `json:"inbounds"`
		}
		if json.Unmarshal(channel, &ch) == nil {
			for _, in := range ch.Inbounds {
				if in["tag"] == "sync" {
					if p := port(in["override_port"]); p != 0 {
						return p
					}
				}
			}
		}
	}
	sj := readJSON(filepath.Join(home, "server.json"))
	if p := port(sj["listen"]); p != 0 {
		return p
	}
	return port(sj["syncPort"])
}
