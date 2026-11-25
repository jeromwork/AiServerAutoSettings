//go:build windows

package autostart

import (
	"encoding/xml"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"unicode/utf16"
)

const taskXML = `<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>{{USER}}</UserId></LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author"><UserId>{{USER}}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>{{CMD}}</Command><Arguments>--autostart</Arguments></Exec>
  </Actions>
</Task>
`

func esc(s string) string {
	var b strings.Builder
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}

func writeUTF16(path, s string) error {
	b := []byte{0xFF, 0xFE}
	for _, c := range utf16.Encode([]rune(s)) {
		b = append(b, byte(c), byte(c>>8))
	}
	return os.WriteFile(path, b, 0o600)
}

// Задача планировщика при входе текущего пользователя, обычные права, работает и от батареи.
func Enable(exe string) error {
	if strings.ContainsAny(exe, "\"\r\n") {
		return fmt.Errorf("autostart: bad path")
	}
	u, err := user.Current()
	if err != nil {
		return err
	}
	x := strings.NewReplacer("{{USER}}", esc(u.Username), "{{CMD}}", esc(exe)).Replace(taskXML)
	f := filepath.Join(os.TempDir(), "ra-autostart-task.xml")
	if err := writeUTF16(f, x); err != nil {
		return err
	}
	defer os.Remove(f)
	return run("schtasks.exe", "/Create", "/TN", id, "/XML", f, "/F")
}

func Disable() error {
	if !Enabled() {
		return nil
	}
	return run("schtasks.exe", "/Delete", "/TN", id, "/F")
}

func Enabled() bool { return run("schtasks.exe", "/Query", "/TN", id) == nil }
