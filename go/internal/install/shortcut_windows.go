//go:build windows

package install

import (
	"os"
	"os/exec"
	"strings"
	"syscall"

	"golang.org/x/sys/windows"
)

func desktopDir() string {
	if d, err := windows.KnownFolderPath(windows.FOLDERID_Desktop, 0); err == nil && d != "" {
		return d
	}
	return ""
}

// Ярлыки правит PowerShell + WScript.Shell (параметры через окружение, без кавычек в тексте).
// Любой ярлык рабочего стола на другой remoteagents*.exe (старый RA3test и т. п.) переписывается на постоянный путь;
// если ярлыка нет совсем — создаётся один «RemoteAgents 3». Дублей не создаётся.
const syncScript = `$ErrorActionPreference='Stop'
$sh=New-Object -ComObject WScript.Shell
$perm=$env:RA_PERM; $dir=$env:RA_DESK; $args1='supervise --home "'+$env:RA_HOME+'"'
$found=0
Get-ChildItem -LiteralPath $dir -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
  $l=$sh.CreateShortcut($_.FullName)
  if ($l.TargetPath -match '(?i)\\remoteagents[^\\]*\.exe$') {
    $found++
    if ($l.TargetPath -ne $perm -or $l.Arguments -ne $args1) {
      $old=$l.TargetPath
      $l.TargetPath=$perm; $l.Arguments=$args1; $l.WorkingDirectory=$env:RA_HOME; $l.IconLocation=$perm+',0'; $l.Save()
      Write-Output ('обновлён '+$_.Name+' (был '+$old+')')
    } else { Write-Output ('актуален '+$_.Name) }
  }
}
if ($found -eq 0) {
  $f=Join-Path $dir ($env:RA_NAME+'.lnk')
  $l=$sh.CreateShortcut($f)
  $l.TargetPath=$perm; $l.Arguments=$args1; $l.WorkingDirectory=$env:RA_HOME; $l.IconLocation=$perm+',0'; $l.Save()
  Write-Output ('создан '+$env:RA_NAME+'.lnk')
}`

const removeScript = `$ErrorActionPreference='Stop'
$sh=New-Object -ComObject WScript.Shell
Get-ChildItem -LiteralPath $env:RA_DESK -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
  $l=$sh.CreateShortcut($_.FullName)
  if ($l.TargetPath -ieq $env:RA_PERM) { Remove-Item -LiteralPath $_.FullName -Force; Write-Output ('удалён '+$_.Name) }
}
schtasks /Delete /TN RemoteAgents3 /F 2>$null | Out-Null`

func runPS(script string, env ...string) []string {
	cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script)
	cmd.Env = append(os.Environ(), env...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
	out, err := cmd.CombinedOutput()
	var lines []string
	for _, l := range strings.Split(strings.ReplaceAll(string(out), "\r", ""), "\n") {
		if l = strings.TrimSpace(l); l != "" {
			lines = append(lines, l)
		}
	}
	if err != nil {
		lines = append(lines, "ошибка: "+err.Error())
	}
	return lines
}

func syncShortcut(perm, home string) []string {
	d := desktopDir()
	if d == "" {
		return []string{"рабочий стол не найден"}
	}
	return runPS(syncScript, "RA_PERM="+perm, "RA_HOME="+home, "RA_DESK="+d, "RA_NAME="+ShortcutName)
}

func removeShortcuts(perm string) []string {
	d := desktopDir()
	if d == "" {
		return []string{"рабочий стол не найден"}
	}
	return runPS(removeScript, "RA_PERM="+perm, "RA_DESK="+d)
}
