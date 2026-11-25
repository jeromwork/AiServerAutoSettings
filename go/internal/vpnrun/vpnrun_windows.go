//go:build windows

package vpnrun

import (
	"bytes"
	"encoding/csv"
	"strings"
)

// Install (под администратором, один раз): задача с /RL HIGHEST, сама по себе не стартует (ONCE в прошлом).
func (r *Runner) Install(singbox, config string) error {
	if err := badPath(singbox, config); err != nil {
		return err
	}
	_, err := run("schtasks.exe", "/Create", "/TN", label, "/SC", "ONCE", "/ST", "00:00", "/SD", "01/01/2000",
		"/RL", "HIGHEST", "/F", "/TR", `"`+singbox+`" run -c "`+config+`"`)
	return err
}

func (r *Runner) Uninstall() error {
	_, err := run("schtasks.exe", "/Delete", "/TN", label, "/F")
	return err
}

// Start/Stop — без прав: задача уже создана с повышенными.
func (r *Runner) Start() error { _, err := run("schtasks.exe", "/Run", "/TN", label); return err }
func (r *Runner) Stop() error  { _, err := run("schtasks.exe", "/End", "/TN", label); return err }

// Running: столбец «Состояние» (4-й) = Running / «Выполняется» (в OEM-кодировке cp866).
func (r *Runner) Running() bool {
	out, err := run("schtasks.exe", "/Query", "/TN", label, "/FO", "CSV", "/V")
	if err != nil {
		return false
	}
	rows, err := csv.NewReader(bytes.NewReader([]byte(out))).ReadAll()
	if err != nil || len(rows) < 2 || len(rows[1]) < 4 {
		return false
	}
	s := rows[1][3]
	return strings.EqualFold(s, "Running") || s == "\x82\xeb\xaf\xae\xab\xad\xef\xe5\xe2\xe1\xef"
}
