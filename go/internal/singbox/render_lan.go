package singbox

import (
	"encoding/json"
	"fmt"
	"net"
	"strconv"
	"strings"

	"remoteagents/internal/api"
)

// RenderLAN is tun.py launch_part's ready LAN plan. Only vpnrun may run this
// TUN configuration: sing-box №1 always stays an ordinary child without rights.
func RenderLAN(rc api.RenderContext) (api.Part, error) { return renderLAN(rc) }
func renderLAN(rc api.RenderContext) (api.Part, error) {
	if rc.Cfg == nil || !lanWanted(rc) || !rc.Mode.AllowsTun() || rc.LANSocks == "" || len(rc.LANRoutes) == 0 {
		return api.Part{}, nil
	}
	host, port, err := net.SplitHostPort(rc.LANSocks)
	if err != nil {
		return api.Part{}, err
	}
	p, err := strconv.Atoi(port)
	if err != nil {
		return api.Part{}, err
	}
	address := rc.Cfg.Tun.Address
	if address == "" {
		address = "172.19.0.1/30"
	}
	return api.Part{
		Inbounds:  []map[string]any{{"type": "tun", "tag": "tun-in", "interface_name": "RA2-LAN", "address": []string{address}, "mtu": 1400, "auto_route": true, "strict_route": false, "route_address": rc.LANRoutes, "stack": "system", "dns_mode": "disabled"}},
		Outbounds: []map[string]any{{"type": "socks", "tag": "tun-lan", "server": host, "server_port": p, "version": "5"}},
		Rules:     []map[string]any{{"inbound": "tun-in", "outbound": "tun-lan"}},
	}, nil
}

// LAN в конфиге уже означает TUN; прежний отдельный tun.enabled не требуется.
func lanWanted(rc api.RenderContext) bool {
	if rc.Cfg == nil {
		return false
	}
	if rc.Effective.LAN {
		return true
	}
	for _, it := range rc.Cfg.LAN {
		if it.Share.Enabled {
			return true
		}
	}
	var raw struct {
		LAN []struct {
			Share struct {
				Enabled *bool `json:"enabled"`
			} `json:"share"`
		} `json:"lan"`
		Profile struct {
			LAN []struct {
				Share struct {
					Enabled *bool `json:"enabled"`
				} `json:"share"`
			} `json:"lan"`
		} `json:"profile"`
	}
	_ = json.Unmarshal(rc.Cfg.Raw, &raw)
	items := raw.LAN
	if items == nil {
		items = raw.Profile.LAN
	}
	for _, it := range items {
		if it.Share.Enabled == nil || *it.Share.Enabled {
			return true
		}
	}
	return false
}

// DNS берём из публичного share.dnsServers, как в docs/VPN-LAN.md.
func lanDNS(cfg *api.Config) []api.LANDNS {
	var raw struct {
		LAN     json.RawMessage `json:"lan"`
		Profile struct {
			LAN json.RawMessage `json:"lan"`
		} `json:"profile"`
	}
	_ = json.Unmarshal(cfg.Raw, &raw)
	data := raw.LAN
	if len(data) == 0 || string(data) == "null" {
		data = raw.Profile.LAN
	}
	var items []struct {
		Share struct {
			Enabled *bool    `json:"enabled"`
			Domains []string `json:"domains"`
			Servers []string `json:"dnsServers"`
		} `json:"share"`
	}
	_ = json.Unmarshal(data, &items)
	var out []api.LANDNS
	for _, it := range items {
		if it.Share.Enabled != nil && !*it.Share.Enabled {
			continue
		}
		n := api.LANDNS{Servers: it.Share.Servers}
		for _, d := range it.Share.Domains {
			d = vpnIDNA(strings.TrimPrefix(d, "*."))
			if d != "" && !strings.ContainsAny(d, "*?/\\: \r\n") {
				n.Domains = append(n.Domains, d)
			}
		}
		if len(n.Domains) > 0 {
			out = append(out, n)
		}
	}
	return out
}

func addLANDNS(conf map[string]any, rc api.RenderContext) (string, []string, error) {
	plans := rc.LANDNS
	if plans == nil {
		plans = lanDNS(rc.Cfg)
	}
	var servers, rules []map[string]any
	var domains []string
	for i, p := range plans {
		if len(p.Domains) == 0 {
			continue
		}
		if len(p.Servers) == 0 {
			continue
		}
		// DNS транспорта TCP проходит через SOCKS канала, без UDP ASSOCIATE в forward.
		tag := fmt.Sprintf("lan-dns-%d", i)
		servers = append(servers, map[string]any{"type": "tcp", "tag": tag, "server": p.Servers[0], "server_port": 53, "detour": "tun-lan"})
		rules = append(rules, map[string]any{"domain_suffix": p.Domains, "action": "route", "server": tag})
		domains = append(domains, p.Domains...)
	}
	if len(domains) == 0 {
		return "", nil, nil
	}
	address := rc.Cfg.Tun.Address
	if address == "" {
		address = "172.19.0.1/30"
	}
	ip, _, err := net.ParseCIDR(address)
	if err != nil {
		return "", nil, err
	}
	// Остальные имена отклоняются: системному DNS этот слушатель не подменяет резолвер.
	rules = append(rules, map[string]any{"action": "reject"})
	conf["dns"] = map[string]any{"servers": servers, "rules": rules}
	ins := conf["inbounds"].([]map[string]any)
	conf["inbounds"] = append(ins, map[string]any{"type": "direct", "tag": "lan-dns-in", "listen": ip.String(), "listen_port": 53})
	route := conf["route"].(map[string]any)
	route["rules"] = append([]map[string]any{{"inbound": "lan-dns-in", "action": "hijack-dns"}}, route["rules"].([]map[string]any)...)
	return ip.String(), domains, nil
}
