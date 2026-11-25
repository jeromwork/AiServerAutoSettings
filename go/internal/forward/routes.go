package forward

import (
	"context"
	"net"
	"sort"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/api"
)

// LANRoutes — tun.py _routes/_domain_ips. Вызывается на старте, net.changed и channel.up.
// Только IPv4; сеть с адресом самого ПК пропускается. DNS ограничен одним действием в 5 с.
func LANRoutes(ctx context.Context, cfg *api.Config) ([]string, error) {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil, err
	}
	var local []net.IP
	for _, a := range addrs {
		ip, _, _ := net.ParseCIDR(a.String())
		if ip.To4() != nil {
			local = append(local, ip)
		}
	}
	routes := map[string]bool{}
	add := func(n *net.IPNet) {
		if n == nil || n.IP.To4() == nil {
			return
		}
		for _, ip := range local {
			if n.Contains(ip) {
				return
			}
		}
		routes[n.String()] = true
	}
	nets := parseNets(cfg)
	var hosts []string
	seen := map[string]bool{}
	count := 0
	for _, n := range nets {
		for _, p := range n.nets {
			if count < 128 {
				add(p)
				count++
			}
		}
		for _, d := range n.domains {
			h := strings.TrimPrefix(d, "*.")
			if h != "" && !strings.ContainsAny(h, "*?") && !seen[h] && len(hosts) < 16 {
				seen[h] = true
				hosts = append(hosts, h)
			}
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var wg sync.WaitGroup
	var mu sync.Mutex
	for _, h := range hosts {
		wg.Add(1)
		go func(h string) {
			defer wg.Done()
			ips, _ := net.DefaultResolver.LookupIP(ctx, "ip4", h)
			mu.Lock()
			defer mu.Unlock()
			for i, ip := range ips {
				if i == 8 {
					break
				}
				add(&net.IPNet{IP: ip.To4(), Mask: net.CIDRMask(32, 32)})
			}
		}(h)
	}
	wg.Wait()
	out := make([]string, 0, len(routes))
	for r := range routes {
		out = append(out, r)
	}
	sort.Strings(out)
	return out, nil
}
