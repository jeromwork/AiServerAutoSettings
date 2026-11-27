package singbox

import "remoteagents/internal/api"

// VPNServerIPs — IP мостов VPN (узлы и пути), к которым должен идти трафик мимо нашего TUN; для pf-якоря галочки на macOS.
func VPNServerIPs(cfg *api.Config) []string {
	if cfg == nil {
		return nil
	}
	sel, err := vpnSelect(cfg)
	if err != nil {
		return nil
	}
	var out []string
	for _, h := range sel.hosts {
		out = append(out, resolveHost(h)...)
	}
	return out
}
