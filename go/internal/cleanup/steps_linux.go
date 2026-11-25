package cleanup

import (
	"net"
	"os/exec"
	"strings"
)

// В v2 уборки для Linux нет. Минимум, без которого ломается сеть: хвост нашего VPN — интерфейс
// и правила маршрутизации sing-box (таблица 2022), оставшиеся после жёсткого убийства.
func (c *Cleaner) steps(mode string) []step { return []step{{"VPN", c.vpnTail}} }

func (c *Cleaner) vpnTail() error {
	ifs, _ := net.Interfaces()
	ours := false // любой наш интерфейс (VPN/LAN) значит, что правила ещё нужны
	for _, i := range ifs {
		if !strings.HasPrefix(i.Name, "RA2-") {
			continue
		}
		ours = true
		if !strings.HasPrefix(i.Name, VPNIface) {
			continue
		}
		if i.Flags&net.FlagUp != 0 {
			c.note("Адаптеры: " + i.Name + " в состоянии Up, удаление пропущено")
		} else if c.reading {
			c.note("Адаптеры: остался интерфейс программы")
		} else if err := c.ip("link", "delete", i.Name); err != nil {
			return err
		}
	}
	if ours {
		return nil
	}
	for _, fam := range []string{"-4", "-6"} {
		out, err := exec.CommandContext(c.ctx, "ip", fam, "rule", "show").Output()
		if err != nil {
			return err
		}
		for _, line := range strings.Split(string(out), "\n") {
			f := strings.Fields(line)
			if len(f) == 0 || !strings.Contains(line, "lookup 2022") {
				continue
			}
			if c.reading {
				c.note("Маршруты: остались правила программы")
			} else if err := c.ip(fam, "rule", "del", "pref", strings.TrimSuffix(f[0], ":")); err != nil {
				return err
			}
		}
	}
	return nil
}

func (c *Cleaner) ip(args ...string) error {
	return exec.CommandContext(c.ctx, "ip", args...).Run()
}
