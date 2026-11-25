package tray

func (t *Tray) open(target string) { t.launch("explorer.exe", target) }
func clipboardCommand() (string, []string) {
	return "powershell.exe", []string{"-NoProfile", "-NonInteractive", "-Command", "Set-Clipboard -Value ([Console]::In.ReadToEnd())"}
}
