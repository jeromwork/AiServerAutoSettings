package cleanup

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const vpnPlist = "/Library/LaunchDaemons/ru.remoteagents.vpn.plist"
const vpnSudoers = "/etc/sudoers.d/ru-remoteagents-vpn"
const vpnDNSHelper = "/Library/PrivilegedHelperTools/ru.remoteagents.vpn-dns"

func (c *Cleaner) steps(mode string) []step {
	var s []step
	if c.reading || mode == "exit" {
		s = append(s, step{"Автозапуск", c.autostart})
	}
	s = append(s, step{"Процессы / utun / маршруты", c.processes}, step{"DNS", c.lanDNS})
	if c.reading || mode == "exit" {
		s = append(s, step{"VPN-служба и права", c.vpnInstall})
	}
	return s
}

// Тот же запрос прав через macOS, что использует vpnrun.Install.
func (c *Cleaner) privileged(script string) error {
	if os.Geteuid() == 0 {
		_, err := c.unixCommand("/bin/sh", "-c", script)
		return err
	}
	escaped := strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(script)
	_, err := c.unixCommand("osascript", "-e", `do shell script "`+escaped+`" with administrator privileges`)
	return err
}

func (c *Cleaner) ownedProcesses() (map[int]string, error) {
	out, err := c.unixCommand("/bin/ps", "-wwaxo", "pid=,comm=")
	if err != nil {
		return nil, err
	}
	result := map[int]string{}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		i := strings.IndexAny(line, " \t")
		if i < 0 {
			continue
		}
		pid, err := strconv.Atoi(line[:i])
		if err == nil {
			result[pid] = strings.TrimSpace(line[i:])
		}
	}
	return result, nil
}

func (c *Cleaner) lanDNS() error {
	files, err := filepath.Glob("/etc/resolver/*")
	if err != nil {
		return err
	}
	for _, path := range files {
		data, err := os.ReadFile(path)
		if err != nil {
			c.note("DNS: не удалось проверить " + path)
			continue
		}
		if !bytes.HasPrefix(data, []byte("# RemoteAgents-Lab RA2-LAN\n")) {
			continue
		}
		cmd := "rm -f -- " + shellQuote(path)
		c.change("DNS: осталось правило "+path, "sudo "+cmd, func() error { return c.privileged(cmd) })
	}
	return nil
}

func (c *Cleaner) vpnInstall() error {
	// Загруженный daemon может остаться и после удаления plist.
	_, loaded := c.unixCommand("/bin/launchctl", "print", "system/ru.remoteagents.vpn")
	if loaded == nil {
		cmd := "/bin/launchctl bootout system/ru.remoteagents.vpn"
		c.change("VPN: осталась служба ru.remoteagents.vpn", "sudo "+cmd, func() error { return c.privileged(cmd) })
	}
	for _, path := range []string{vpnPlist, vpnSudoers, vpnDNSHelper} {
		if _, err := os.Lstat(path); os.IsNotExist(err) {
			continue
		} else if err != nil {
			c.note("VPN: не удалось проверить " + path)
			continue
		}
		cmd := "rm -f -- " + shellQuote(path)
		c.change("VPN: остался "+path, "sudo "+cmd, func() error { return c.privileged(cmd) })
	}
	return nil
}

func (c *Cleaner) autostart() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	c.removeExternal(filepath.Join(home, "Library", "LaunchAgents", "ru.remoteagents.app.plist"))
	target := fmt.Sprintf("gui/%d/ru.remoteagents.app", os.Getuid())
	out, err := c.unixCommand("/bin/launchctl", "print", target)
	if err != nil {
		return nil
	}
	// bootout своего LaunchAgent убил бы уборку. После обычного выхода
	// процесс завершится сам; plist уже снят, повторного входа в автозапуск нет.
	for _, line := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(line) == "pid = "+strconv.Itoa(os.Getpid()) {
			if !c.reading {
				c.note("Автозапуск: plist снят; свой LaunchAgent ещё загружен. После выхода: launchctl bootout " + target)
			}
			return nil
		}
	}
	cmd := "launchctl bootout " + target
	c.change("Автозапуск: остался LaunchAgent", cmd, func() error { _, err := c.unixCommand("/bin/launchctl", "bootout", target); return err })
	return nil
}
