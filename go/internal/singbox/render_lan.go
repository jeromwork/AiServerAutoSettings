package singbox

import (
	"errors"
	"net"
	"net/netip"

	"remoteagents/internal/api"
)

// LANSubnets — подсети клиники из lan[].share.subnets (включённые), без пересечения с адресами самого ПК
// (домашняя сеть не перехватывается, как в tun.py v2). Второй результат — пропущенные.
func LANSubnets(cfg *api.Config) (nets, skipped []string) {
	var local []netip.Prefix
	if as, err := net.InterfaceAddrs(); err == nil {
		for _, a := range as {
			if p, err := netip.ParsePrefix(a.String()); err == nil {
				local = append(local, p.Masked())
			}
		}
	}
	seen := map[string]bool{}
	for _, l := range cfg.LAN {
		if !l.Share.Enabled {
			continue
		}
		for _, s := range l.Share.Subnets {
			p, err := netip.ParsePrefix(s)
			if err != nil {
				a, err2 := netip.ParseAddr(s)
				if err2 != nil {
					continue
				}
				p = netip.PrefixFrom(a, a.BitLen())
			}
			p = p.Masked()
			if seen[p.String()] {
				continue
			}
			seen[p.String()] = true
			clash := false
			for _, lp := range local {
				if lp.Overlaps(p) {
					clash = true
				}
			}
			if clash {
				skipped = append(skipped, p.String())
			} else {
				nets = append(nets, p.String())
			}
		}
	}
	return nets, skipped
}

// LANTunDNS — адрес, который sing-box регистрирует как DNS на интерфейсе ЛВС (второй адрес /30).
const LANTunDNS = "172.19.9.2"

// renderLAN — часть ЛВС (N2, повтор tun.py): tun-in RA3-LAN только на подсети клиники → socks во внутренний
// SOCKS forward (lan-out). DNS/NRPT/hosts не трогаем.
func renderLAN(rc api.RenderContext) (api.Part, error) {
	if rc.LANSocks == "" {
		return api.Part{}, errors.New("singbox: lan: нет внутреннего SOCKS")
	}
	host, port, err := net.SplitHostPort(rc.LANSocks)
	if err != nil {
		return api.Part{}, errors.New("singbox: lan: неверный адрес SOCKS")
	}
	pn, _ := toInt(port)
	nets, _ := LANSubnets(rc.Cfg)
	if len(nets) == 0 {
		return api.Part{}, errors.New("singbox: lan: нет подсетей")
	}
	name := AdapterName(rc.Instance, "lan")
	if name == "" {
		return api.Part{}, errors.New("singbox: lan: instance")
	}
	return api.Part{
		Inbounds: []m{{"type": "tun", "tag": "lan-in", "interface_name": name, "address": []string{"172.19.9.1/30"}, "mtu": 1400,
			"auto_route": true, "strict_route": false, "route_address": nets}},
		Outbounds: []m{{"type": "socks", "tag": "lan-out", "server": host, "server_port": pn, "version": "5"}},
		// Только запросы к DNS самого TUN (172.19.9.2:53) из lan-in; всё остальное (чужой VPN, свои подсети) не трогаем.
		Rules: []m{
			{"inbound": "lan-in", "ip_cidr": []string{LANTunDNS + "/32"}, "port": 53, "action": "hijack-dns"},
			{"ip_cidr": nets, "outbound": "lan-out"},
		},
		DNS: m{
			"servers": []m{
				{"type": "udp", "tag": "dns-up", "server": "1.1.1.1"},
				{"type": "local", "tag": "dns-sys"},
			},
			"final": "dns-up",
		},
	}, nil
}
