package forward

import (
	"encoding/json"
	"net"
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
	items := cfg.LAN
	var rawLAN struct {
		LAN     json.RawMessage `json:"lan"`
		Profile struct {
			LAN json.RawMessage `json:"lan"`
		} `json:"profile"`
	}
	if json.Unmarshal(cfg.Raw, &rawLAN) == nil {
		raw := rawLAN.LAN
		if len(raw) == 0 || string(raw) == "null" {
			raw = rawLAN.Profile.LAN
		}
		var rows []struct {
			Name  string   `json:"name"`
			Nets  []string `json:"nets"`
			Share struct {
				Enabled *bool    `json:"enabled"`
				Subnets []string `json:"subnets"`
				Domains []string `json:"domains"`
			} `json:"share"`
		}
		if json.Unmarshal(raw, &rows) == nil {
			items = nil
			for _, r := range rows {
				items = append(items, api.LANCfg{Name: r.Name, Share: api.LANShare{Enabled: r.Share.Enabled == nil || *r.Share.Enabled, Subnets: append(r.Share.Subnets, r.Nets...), Domains: r.Share.Domains}})
			}
		}
	}
	for i, it := range items {
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
