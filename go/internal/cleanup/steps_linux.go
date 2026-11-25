package cleanup

import (
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func (c *Cleaner) steps(mode string) []step {
	var s []step
	if c.reading || mode == "exit" {
		s = append(s, step{"Автозапуск", c.autostart})
	}
	s = append(s, step{"DNS", c.lanDNS}, step{"Процессы", c.processes}, step{"VPN/LAN", c.vpnTail})
	if c.reading || mode == "exit" {
		s = append(s, step{"Права DNS", c.dnsPermissions})
	}
	return s
}

// Как vpnrun.Install: sudo. Уборка не ждёт пароль в невидимом терминале.
func (c *Cleaner) privileged(script string) error {
	if os.Geteuid() == 0 {
		_, err := c.unixCommand("/bin/sh", "-c", script)
		return err
	}
	_, err := c.unixCommand("sudo", "-n", "/bin/sh", "-c", script)
	return err
}

func (c *Cleaner) ownedProcesses() (map[int]string, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	result := map[int]string{}
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		path, err := os.Readlink(filepath.Join("/proc", entry.Name(), "exe"))
		if os.IsPermission(err) {
			comm, _ := os.ReadFile(filepath.Join("/proc", entry.Name(), "comm"))
			name := strings.TrimSpace(string(comm))
			if !strings.HasPrefix(name, "sing-box") && name != "ra2-vpn" && name != "ra2-lan" && name != "syncthing" {
				continue
			}
			link := filepath.Join("/proc", entry.Name(), "exe")
			out, readErr := c.unixCommand("sudo", "-n", "readlink", link)
			if readErr != nil {
				c.note("Процессы: не удалось определить папку PID " + entry.Name() + "; вручную: sudo readlink " + link + "; если это наша папка — sudo kill -KILL " + entry.Name())
				continue
			}
			path, err = strings.TrimSpace(string(out)), nil
		}
		if err == nil {
			result[pid] = strings.TrimSuffix(path, " (deleted)")
		}
	}
	return result, nil
}

func (c *Cleaner) ip(args ...string) {
	words := []string{"ip"}
	for _, arg := range args {
		words = append(words, shellQuote(arg))
	}
	cmd := strings.Join(words, " ")
	c.change("Сеть: осталось изменение ("+cmd+")", "sudo "+cmd, func() error { return c.privileged(cmd) })
}

func (c *Cleaner) vpnTail() error {
	ifs, err := net.Interfaces()
	if err != nil {
		return err
	}
	for _, iface := range ifs {
		if iface.Name == VPNIface || iface.Name == LANIface {
			c.ip("link", "delete", iface.Name)
		}
	}
	for _, fam := range []string{"-4", "-6"} {
		out, err := c.unixCommand("ip", fam, "rule", "show")
		if err != nil {
			c.note("Сеть: не удалось проверить правила " + fam + "; вручную: ip " + fam + " rule show")
			continue
		}
		for _, line := range strings.Split(string(out), "\n") {
			fields := strings.Fields(line)
			for i := 0; i+1 < len(fields); i++ {
				if (fields[i] == "lookup" || fields[i] == "table") && fields[i+1] == "2022" {
					c.ip(fam, "rule", "del", "pref", strings.TrimSuffix(fields[0], ":"))
					break
				}
			}
		}
		out, err = c.unixCommand("ip", fam, "route", "show", "table", "2022")
		// ip возвращает ошибку и для отсутствующей таблицы.
		if err != nil {
			if strings.Contains(err.Error(), "exit status 2") {
				continue
			}
			c.note("Сеть: не удалось проверить маршруты " + fam + "; вручную: ip " + fam + " route show table 2022")
			continue
		}
		if strings.TrimSpace(string(out)) != "" {
			c.ip(fam, "route", "flush", "table", "2022")
		}
	}
	return nil
}

func (c *Cleaner) lanDNS() error {
	if _, err := net.InterfaceByName(LANIface); err != nil {
		return nil
	}
	if c.reading {
		out, err := c.unixCommand("/usr/bin/resolvectl", "domain", LANIface)
		if err != nil {
			return err
		}
		if strings.Contains(string(out), "~") {
			c.note("DNS: остались правила RA2-LAN; вручную: sudo resolvectl revert RA2-LAN")
		}
		return nil
	}
	// Точный вызов из sudoers vpnrun; sh -c не входит в его NOPASSWD-правило.
	if _, err := c.unixCommand("sudo", "-n", "/usr/bin/resolvectl", "revert", LANIface); err != nil {
		c.note("DNS: не удалось снять настройки RA2-LAN; вручную: sudo resolvectl revert RA2-LAN")
	}
	return nil
}

func (c *Cleaner) autostart() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	const unit = "remoteagents.service"
	out, err := c.unixCommand("systemctl", "--user", "show", unit, "--property=LoadState,MainPID")
	if err == nil && !strings.Contains(string(out), "LoadState=not-found") {
		// Не останавливаем службу с самой уборкой: главный процесс завершится
		// после Run. Отдельный запуск команды уборки останавливает старую службу.
		args := []string{"--user", "disable", "--now", unit}
		for _, line := range strings.Split(string(out), "\n") {
			if line == "MainPID="+strconv.Itoa(os.Getpid()) || line == "MainPID="+strconv.Itoa(os.Getppid()) {
				args = []string{"--user", "disable", unit}
			}
		}
		c.change("Автозапуск: остался systemd --user юнит", "systemctl --user disable --now "+unit, func() error {
			_, err := c.unixCommand("systemctl", args...)
			return err
		})
	} else if err != nil {
		c.note("Автозапуск: не удалось проверить systemd; вручную: systemctl --user disable --now " + unit)
	}
	c.removeExternal(filepath.Join(home, ".config", "systemd", "user", unit))
	if !c.reading {
		if _, err := c.unixCommand("systemctl", "--user", "daemon-reload"); err != nil {
			c.note("Автозапуск: нужен systemctl --user daemon-reload")
		}
	}
	return nil
}

func (c *Cleaner) dnsPermissions() error {
	const path = "/etc/sudoers.d/ru-remoteagents-vpn-dns"
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	cmd := "rm -f -- " + shellQuote(path)
	c.change("Права DNS: осталось "+path, "sudo "+cmd, func() error { return c.privileged(cmd) })
	// setcap сохраняется: это атрибут файла внутри папки программы.
	return nil
}
