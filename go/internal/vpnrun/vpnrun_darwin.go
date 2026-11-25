//go:build darwin

package vpnrun

import (
	"fmt"
	"os"
	"os/user"
	"strings"
)

const (
	plist   = "/Library/LaunchDaemons/" + label + ".plist"
	sudoers = "/etc/sudoers.d/ru-remoteagents-vpn"
	target  = "system/" + label
)

// Install: LaunchDaemon (root, не стартует сам) + правило sudoers только на два точных launchctl-вызова
// (иначе обычный пользователь не сможет kickstart/kill службы в system-домене). Один запрос пароля администратора.
func (r *Runner) Install() error {
	if err := badPath(r.Sing, r.Conf); err != nil {
		return err
	}
	u, err := user.Current()
	if err != nil {
		return err
	}
	pl := `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>` + label + `</string>
<key>ProgramArguments</key><array><string>` + r.Sing + `</string><string>run</string><string>-c</string><string>` + r.Conf + `</string></array>
<key>RunAtLoad</key><false/>
</dict></plist>
`
	sd := u.Username + " ALL=(root) NOPASSWD: /bin/launchctl kickstart -k " + target + ", /bin/launchctl kill TERM " + target + "\n"
	tp, ts := os.TempDir()+"/ra-vpn.plist", os.TempDir()+"/ra-vpn.sudoers"
	if err := os.WriteFile(tp, []byte(pl), 0o600); err != nil {
		return err
	}
	if err := os.WriteFile(ts, []byte(sd), 0o600); err != nil {
		return err
	}
	defer os.Remove(tp)
	defer os.Remove(ts)
	sh := fmt.Sprintf("/usr/sbin/visudo -cf %[3]s && install -m 644 -o root -g wheel %[1]s %[2]s && install -m 440 -o root -g wheel %[3]s %[4]s && /bin/launchctl bootout %[5]s 2>/dev/null; /bin/launchctl bootstrap system %[2]s",
		tp, plist, ts, sudoers, target)
	_, err = run("osascript", "-e", `do shell script "`+strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(sh)+`" with administrator privileges`)
	if err != nil {
		return err
	}
	return nil
}

func (r *Runner) Uninstall() error {
	sh := "/bin/launchctl bootout " + target + "; rm -f " + plist + " " + sudoers
	_, err := run("osascript", "-e", `do shell script "`+sh+`" with administrator privileges`)
	return err
}

func (r *Runner) start() error {
	_, err := run("sudo", "-n", "/bin/launchctl", "kickstart", "-k", target)
	return err
}

func (r *Runner) stop() error {
	_, err := run("sudo", "-n", "/bin/launchctl", "kill", "TERM", target)
	return err
}

// Running: в `launchctl print` у работающей службы есть строка «state = running» (print не требует root).
func (r *Runner) Running() bool {
	out, err := run("launchctl", "print", target)
	return err == nil && strings.Contains(string(out), "state = running")
}

// exited: sing-box здесь не наш ребёнок — события выхода нет, о смерти узнаём по обрыву API.
func (r *Runner) exited() <-chan struct{} { return nil }
