package tray

import "os"

func (t *Tray) open(target string) { t.launch("xdg-open", target) }
func clipboardCommand() (string, []string) {
	if os.Getenv("WAYLAND_DISPLAY") != "" {
		return "wl-copy", []string{"--foreground"}
	}
	return "xclip", []string{"-selection", "clipboard", "-quiet"}
}
