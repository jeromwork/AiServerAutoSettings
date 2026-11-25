package cleanup

import (
	"bytes"
	"os"
	"path/filepath"
	"remoteagents/internal/vpnrun"
)

// utun исчезает вместе с sing-box; собственные resolver-файлы снимает помощник vpnrun.
func (c *Cleaner) steps(mode string) []step { return []step{{"DNS", c.lanDNS}} }
func (c *Cleaner) lanDNS() error {
	files, err := filepath.Glob("/etc/resolver/*")
	if err != nil {
		return err
	}
	for _, path := range files {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if !bytes.HasPrefix(data, []byte("# RemoteAgents-Lab RA2-LAN\n")) {
			continue
		}
		if c.reading {
			c.note("DNS: остались правила программы")
			return nil
		}
		return (&vpnrun.Runner{Conf: filepath.Join(c.home, "private", "vpn.json")}).ClearDNS(c.ctx)
	}
	return nil
}
