package forward

import (
	"encoding/json"
	"fmt"
	"net"
	"path"
	"strings"

	"remoteagents/internal/api"
)

type lanNet struct {
	name    string
	nets    []*net.IPNet
	domains []string
}

// parseNets: сети из lan[] (share) + happier-api (happier.viaChannel, по умолчанию api.happier.dev).
func parseNets(cfg *api.Config) []lanNet {
	var out []lanNet
	for i, it := range cfg.LAN {
		if i >= 64 {
			break
		}
		if it.Name == "" || !it.Share.Enabled {
			continue
		}
		var n lanNet
		n.name = it.Name
		for _, s := range it.Share.Subnets {
			if x := parseNet(s); x != nil {
				n.nets = append(n.nets, x)
			}
		}
		for _, d := range it.Share.Domains {
			if d != "" {
				n.domains = append(n.domains, strings.ToLower(d))
			}
		}
		if len(n.nets) > 0 || len(n.domains) > 0 {
			out = append(out, n)
		}
	}
	via := []string{"api.happier.dev"}
	var raw struct {
		Happier struct {
			ViaChannel *[]any `json:"viaChannel"`
		} `json:"happier"`
	}
	if json.Unmarshal(cfg.Raw, &raw) == nil && raw.Happier.ViaChannel != nil {
		via = nil
		for _, v := range *raw.Happier.ViaChannel {
			if s, ok := v.(string); ok && s != "" {
				via = append(via, strings.ToLower(s))
			}
		}
	}
	if len(via) > 0 {
		out = append(out, lanNet{name: "happier-api", domains: via})
	}
	return out
}

func parseNet(s string) *net.IPNet {
	if _, x, err := net.ParseCIDR(strings.TrimSpace(s)); err == nil {
		return x
	}
	if ip := net.ParseIP(strings.TrimSpace(s)); ip != nil {
		bits := 128
		if ip.To4() != nil {
			ip, bits = ip.To4(), 32
		}
		return &net.IPNet{IP: ip, Mask: net.CIDRMask(bits, bits)}
	}
	return nil
}

// withServer: сам сервер тоже «сеть» (его порты с ПК режет ТСПУ, через канал открываются).
func withServer(nets []lanNet, cfg *api.Config) []lanNet {
	if len(cfg.Servers) == 0 {
		return nets
	}
	if x := parseNet(cfg.Servers[0].Host); x != nil {
		return append(nets, lanNet{name: "server", nets: []*net.IPNet{x}})
	}
	return nets
}

// match -> имя сети или "". host — IP или домен.
func match(nets []lanNet, host string) string {
	h := strings.TrimRight(strings.ToLower(host), ".")
	if ip := net.ParseIP(h); ip != nil {
		for _, n := range nets {
			for _, x := range n.nets {
				if x.Contains(ip) {
					return n.name
				}
			}
		}
		return ""
	}
	for _, n := range nets {
		for _, d := range n.domains {
			if ok, _ := path.Match(d, h); ok || (strings.HasPrefix(d, "*.") && h == d[2:]) {
				return n.name
			}
		}
	}
	return ""
}

func pacText(nets []lanNet, port int) string {
	var b strings.Builder
	fmt.Fprintf(&b, "function FindProxyForURL(url, host) {\n  var P = \"PROXY 127.0.0.1:%d\";\n  host = host.toLowerCase();\n", port)
	for _, n := range nets {
		for _, d := range n.domains {
			extra := ""
			if strings.HasPrefix(d, "*.") {
				extra = fmt.Sprintf(" || host == \"%s\"", d[2:])
			}
			fmt.Fprintf(&b, "  if (shExpMatch(host, \"%s\")%s) return P;\n", d, extra)
		}
	}
	for _, n := range nets {
		for _, x := range n.nets {
			if x.IP.To4() != nil && len(x.Mask) == 4 {
				fmt.Fprintf(&b, "  if (isInNet(host, \"%s\", \"%s\")) return P;\n", x.IP.To4(), net.IP(x.Mask))
			}
		}
	}
	b.WriteString("  return \"DIRECT\";\n}\n")
	return b.String()
}
