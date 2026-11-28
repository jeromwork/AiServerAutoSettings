package update

import (
	"context"
	"net"
	"time"
)

type lookupFn func(ctx context.Context, host string) ([]string, error)

// Запасные публичные резолверы (UDP, напрямую).
var fallbackDNS = []string{"1.1.1.1:53", "8.8.8.8:53"}

func systemLookup(ctx context.Context, host string) ([]string, error) {
	return net.DefaultResolver.LookupHost(ctx, host)
}

func fallbackLookup(ctx context.Context, host string) ([]string, error) {
	var last error
	for _, srv := range fallbackDNS {
		srv := srv
		r := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 4 * time.Second}).DialContext(ctx, "udp", srv)
		}}
		cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		ips, err := r.LookupHost(cctx, host)
		cancel()
		if err == nil && len(ips) > 0 {
			return ips, nil
		}
		last = err
	}
	if last == nil {
		last = &net.DNSError{Err: "no addresses", Name: host}
	}
	return nil, last
}

// newDialContext: резолв отдельно от dial. Системный DNS (до sysTimeout), при ошибке — запасной;
// затем dial на IP с таймаутом dialTimeout. TLS идёт по имени узла (его знает Transport).
func newDialContext(dialTimeout, sysTimeout time.Duration, sys, fb lookupFn) func(ctx context.Context, network, addr string) (net.Conn, error) {
	dialer := &net.Dialer{Timeout: dialTimeout}
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(addr)
		if err != nil || net.ParseIP(host) != nil {
			return dialer.DialContext(ctx, network, addr)
		}
		sctx, cancel := context.WithTimeout(ctx, sysTimeout)
		ips, err := sys(sctx, host)
		cancel()
		if (err != nil || len(ips) == 0) && ctx.Err() == nil {
			step(ctx, "checking", "системный DNS медленный, использую запасной")
			ips, err = fb(ctx, host)
		}
		if err != nil {
			return nil, err
		}
		var last error
		for _, ip := range ips {
			c, derr := dialer.DialContext(ctx, network, net.JoinHostPort(ip, port))
			if derr == nil {
				return c, nil
			}
			last = derr
			if ctx.Err() != nil {
				break
			}
		}
		return nil, last
	}
}
