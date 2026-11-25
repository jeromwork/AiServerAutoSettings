//go:build windows

package vpnrun

import (
	"context"
	"encoding/xml"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf16"
)

const taskXML = `<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <Enabled>true</Enabled>
  </Settings>
  <Principals>
    <Principal id="Author"><RunLevel>HighestAvailable</RunLevel></Principal>
  </Principals>
  <Actions Context="Author">
    <Exec><Command>{{CMD}}</Command><Arguments>{{ARGS}}</Arguments></Exec>
  </Actions>
</Task>
`

func esc(s string) string {
	var b strings.Builder
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}

// writeUTF16 пишет файл в UTF-16LE с BOM (формат, который schtasks принимает всегда).
func writeUTF16(path, s string) error {
	u := utf16.Encode([]rune(s))
	b := []byte{0xFF, 0xFE}
	for _, c := range u {
		b = append(b, byte(c), byte(c>>8))
	}
	return os.WriteFile(path, b, 0o600)
}

// Install (под администратором, один раз): задача HighestAvailable из XML, работает и от батареи,
// без лимита времени; сама не стартует (триггеров нет).
func (r *Runner) Install() error {
	if err := badPath(r.Sing, r.Conf); err != nil {
		return err
	}
	x := strings.NewReplacer("{{CMD}}", esc(r.Sing), "{{ARGS}}", esc(`run -c "`+r.Conf+`"`)).Replace(taskXML)
	f := filepath.Join(os.TempDir(), "ra-vpn-task.xml")
	if err := writeUTF16(f, x); err != nil {
		return err
	}
	defer os.Remove(f)
	if _, err := run("schtasks.exe", "/Create", "/TN", label, "/XML", f, "/F"); err != nil {
		return err
	}
	return nil
}

func (r *Runner) Uninstall() error {
	_, err := run("schtasks.exe", "/Delete", "/TN", label, "/F")
	return err
}

// start/stop — без прав: задача уже создана с повышенными.
func (r *Runner) start() error { _, err := run("schtasks.exe", "/Run", "/TN", label); return err }
func (r *Runner) stop(ctx context.Context) error {
	_, err := runContext(ctx, "schtasks.exe", "/End", "/TN", label)
	return err
}

// Running: состояние задачи из PowerShell (значение enum не локализуется).
func (r *Runner) Running() bool {
	out, err := run("powershell.exe", "-NoProfile", "-Command", "(Get-ScheduledTask -TaskName '"+label+"').State")
	return err == nil && strings.TrimSpace(string(out)) == "Running"
}

// exited: sing-box здесь не наш ребёнок — события выхода нет, о смерти узнаём по обрыву API.
func (r *Runner) exited() <-chan struct{} { return nil }
