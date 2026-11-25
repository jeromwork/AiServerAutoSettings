package agent

import (
	"encoding/json"
	"os"
	"path/filepath"

	"remoteagents/internal/api"
)

// CtrlText — ответ, когда «Управление компьютером» выключено (v2 control.py).
const CtrlText = "Управление компьютером запрещено на этом ПК"

func ctrlPath(p api.Paths) string { return filepath.Join(p.State, "control.json") }

// Enabled читает <State>/control.json {"enabled": bool}; нет файла или он битый — разрешено.
func Enabled(p api.Paths) bool {
	b, err := os.ReadFile(ctrlPath(p))
	if err != nil {
		return true
	}
	var d struct {
		Enabled *bool `json:"enabled"`
	}
	if json.Unmarshal(b, &d) != nil || d.Enabled == nil {
		return true
	}
	return *d.Enabled
}

// SetEnabled пишет переключатель атомарно (файл .tmp + rename).
func SetEnabled(p api.Paths, on bool) error {
	f := ctrlPath(p)
	if err := os.MkdirAll(filepath.Dir(f), 0o755); err != nil {
		return err
	}
	b, _ := json.Marshal(map[string]bool{"enabled": on})
	if err := os.WriteFile(f+".tmp", b, 0o644); err != nil {
		return err
	}
	return os.Rename(f+".tmp", f)
}
