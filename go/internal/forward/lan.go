package forward

import (
	"fmt"
	"net"
	"path/filepath"
	"strconv"
	"strings"

	"remoteagents/internal/api"
)

type lanNetwork struct {
	Name    string
	Subnets []*net.IPNet
	Domains []string
}

func parseNets(cfg *api.Config) []lanNetwork {
	var nets []lanNetwork
	if cfg == nil {
		return nets
	}

	for _, item := range cfg.LAN {
		if item.Name == "" || !item.Share.Enabled {
			continue
		}
		var subnets []*net.IPNet
		for _, s := range item.Share.Subnets {
			s = strings.TrimSpace(s)
			if s == "" {
				continue
			}
			if !strings.Contains(s, "/") {
				if ip := net.ParseIP(s); ip != nil {
					if ip.To4() != nil {
						s += "/32"
					} else {
						s += "/128"
					}
				}
			}
			if _, ipNet, err := net.ParseCIDR(s); err == nil {
				subnets = append(subnets, ipNet)
			}
		}
		var domains []string
		for _, d := range item.Share.Domains {
			d = strings.ToLower(strings.TrimSpace(d))
			if d != "" {
				domains = append(domains, d)
			}
		}
		if len(subnets) > 0 || len(domains) > 0 {
			nets = append(nets, lanNetwork{
				Name:    item.Name,
				Subnets: subnets,
				Domains: domains,
			})
		}
	}

	// happier-api default domain
	nets = append(nets, lanNetwork{
		Name:    "happier-api",
		Domains: []string{"api.happier.dev"},
	})

	// Server host if available
	if len(cfg.Servers) > 0 {
		serverHost := strings.TrimSpace(cfg.Servers[0].Host)
		if serverHost != "" {
			if ip := net.ParseIP(serverHost); ip != nil {
				mask := "/32"
				if ip.To4() == nil {
					mask = "/128"
				}
				if _, ipNet, err := net.ParseCIDR(serverHost + mask); err == nil {
					nets = append(nets, lanNetwork{
						Name:    "server",
						Subnets: []*net.IPNet{ipNet},
					})
				}
			} else {
				nets = append(nets, lanNetwork{
					Name:    "server",
					Domains: []string{strings.ToLower(serverHost)},
				})
			}
		}
	}

	return nets
}

func matchLAN(nets []lanNetwork, host string) string {
	h := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
	if h == "" {
		return ""
	}

	ip := net.ParseIP(h)
	if ip != nil {
		for _, n := range nets {
			for _, sub := range n.Subnets {
				if sub.Contains(ip) {
					return n.Name
				}
			}
		}
		return ""
	}

	for _, n := range nets {
		for _, d := range n.Domains {
			if matchDomain(d, h) {
				return n.Name
			}
		}
	}

	return ""
}

func matchDomain(pattern, host string) bool {
	if pattern == host {
		return true
	}
	if strings.HasPrefix(pattern, "*.") {
		root := pattern[2:]
		if host == root || strings.HasSuffix(host, pattern[1:]) {
			return true
		}
	}
	matched, err := filepath.Match(pattern, host)
	return err == nil && matched
}

func pacText(nets []lanNetwork, port int) string {
	var sb strings.Builder
	sb.WriteString("function FindProxyForURL(url, host) {\n")
	fmt.Fprintf(&sb, "  var P = \"PROXY 127.0.0.1:%d\";\n", port)
	sb.WriteString("  host = host.toLowerCase();\n")

	for _, n := range nets {
		for _, d := range n.Domains {
			if strings.HasPrefix(d, "*.") {
				fmt.Fprintf(&sb, "  if (shExpMatch(host, %q) || host == %q) return P;\n", d, d[2:])
			} else {
				fmt.Fprintf(&sb, "  if (shExpMatch(host, %q)) return P;\n", d)
			}
		}
	}

	for _, n := range nets {
		for _, x := range n.Subnets {
			ip4 := x.IP.To4()
			if ip4 != nil {
				mask := net.IP(x.Mask).To4()
				fmt.Fprintf(&sb, "  if (isInNet(host, %q, %q)) return P;\n", ip4.String(), mask.String())
			}
		}
	}

	sb.WriteString("  return \"DIRECT\";\n")
	sb.WriteString("}\n")
	return sb.String()
}

func parseHostPort(addr string) (string, int, error) {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return "", 0, err
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		return "", 0, err
	}
	return host, port, nil
}
