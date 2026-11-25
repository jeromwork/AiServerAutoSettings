package singbox

import (
	"net"
	"strconv"

	"remoteagents/internal/api"
)

// RenderLAN is tun.py launch_part's ready LAN plan. Only vpnrun may run this
// TUN configuration: sing-box №1 always stays an ordinary child without rights.
func RenderLAN(rc api.RenderContext) (api.Part, error) { return renderLAN(rc) }
func renderLAN(rc api.RenderContext) (api.Part, error) {
	if rc.Cfg == nil || !rc.Effective.LAN || !rc.Cfg.Tun.Enabled || !rc.Mode.AllowsTun() || rc.LANSocks == "" || len(rc.LANRoutes) == 0 {
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
