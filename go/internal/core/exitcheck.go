package core

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"

	"remoteagents/internal/api"
)

// exitResult — итог проверки внешнего адреса выхода. OK — ip входит в ожидаемые адреса (Expected); при пустом Expected OK не определён (Known=false).
type exitResult struct {
	IP       string   `json:"ip"`
	Via      string   `json:"via"`
	OK       bool     `json:"ok"`
	Known    bool     `json:"known"` // есть с чем сравнивать (vpn.exitIPs или IP узлов)
	Expected []string `json:"expected"`
	Err      string   `json:"error,omitempty"`
	At       string   `json:"at"`
	Reason   string   `json:"reason,omitempty"` // событие, вызвавшее проверку
}

var exitURLs = []string{"https://api.ipify.org", "https://ifconfig.me/ip", "https://www.cloudflare.com/cdn-cgi/trace"}

// expectedExitIPs — vpn.exitIPs; пусто → IP узлов vpn.nodes (поле server, если это IP-адрес).
func expectedExitIPs(cfg *api.Config) []string {
	if cfg == nil {
		return nil
	}
	if len(cfg.VPN.ExitIPs) > 0 {
		return cfg.VPN.ExitIPs
	}
	var out []string
	for _, raw := range cfg.VPN.Nodes {
		var o struct {
			Server string `json:"server"`
		}
		if json.Unmarshal(raw, &o) == nil {
			if ip, err := netip.ParseAddr(o.Server); err == nil {
				out = append(out, ip.String())
			}
		}
	}
	return out
}

// parseExitIP — тело ответа: просто IP либо cloudflare trace (строка ip=...).
func parseExitIP(body string) string {
	body = strings.TrimSpace(body)
	if ip, err := netip.ParseAddr(body); err == nil {
		return ip.String()
	}
	for _, ln := range strings.Split(body, "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(ln), "ip="); ok {
			if ip, err := netip.ParseAddr(v); err == nil {
				return ip.String()
			}
		}
	}
	return ""
}

// fetchExitIP — внешний адрес без системного прокси; первый успешный из exitURLs. remote — адрес сервера проверки (для определения интерфейса выхода).
func fetchExitIP(ctx context.Context) (ip, remote string, err error) {
	return fetchExitIPVia(ctx, nil)
}

// fetchExitIPVia — то же через прокси proxy (nil — без прокси). remote — адрес, к которому подключился клиент (при прокси это сам прокси).
func fetchExitIPVia(ctx context.Context, proxy *url.URL) (ip, remote string, err error) {
	var last error = errors.New("нет адресов проверки")
	for _, u := range exitURLs {
		var rem string
		d := &net.Dialer{Timeout: 5 * time.Second}
		tr := &http.Transport{Proxy: proxyFn(proxy), DisableKeepAlives: true,
			DialContext: func(ctx context.Context, n, a string) (net.Conn, error) {
				cn, err := d.DialContext(ctx, n, a)
				if err == nil {
					rem = cn.RemoteAddr().String()
				}
				return cn, err
			}}
		cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		req, _ := http.NewRequestWithContext(cctx, http.MethodGet, u, nil)
		resp, e := (&http.Client{Transport: tr}).Do(req)
		if e == nil {
			b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			resp.Body.Close()
			if p := parseExitIP(string(b)); resp.StatusCode == 200 && p != "" {
				cancel()
				tr.CloseIdleConnections()
				return p, rem, nil
			}
			e = errors.New(u + ": неожиданный ответ")
		}
		cancel()
		tr.CloseIdleConnections()
		last = e
	}
	return "", "", last
}

func proxyFn(u *url.URL) func(*http.Request) (*url.URL, error) {
	if u == nil {
		return nil
	}
	return http.ProxyURL(u)
}

// checkExit — одна проверка выхода (по событию). Если уже идёт — не запускает вторую. Результат кладётся в снимок статуса VPN.
func (g *tunGuard) checkExit(ctx context.Context, reason string) {
	if !g.exitBusy.CompareAndSwap(false, true) {
		return
	}
	defer g.exitBusy.Store(false)
	c := g.c
	res := exitResult{Expected: expectedExitIPs(c.cfg), At: time.Now().Format(time.RFC3339), Reason: reason}
	res.Known = len(res.Expected) > 0
	ip, rem, err := fetchExitIP(ctx)
	if err != nil {
		res.Err = sanitize(err.Error())
	} else {
		res.IP = ip
		if h, _, e := net.SplitHostPort(rem); e == nil {
			res.Via = c.plat.ExitIface(net.JoinHostPort(h, "443"))
		}
		for _, x := range res.Expected {
			if x == ip {
				res.OK = true
			}
		}
	}
	g.exit.Store(res)
	g.mu.Lock()
	g.event("vpn.exit", "ip", res.IP, "via", res.Via, "ok", res.OK, "known", res.Known, "reason", reason)
	g.mu.Unlock()
}

// CheckExit — кнопка «Проверить»: проверка выхода сейчас, возвращает итог.
func (c *core) CheckExit(ctx context.Context) (map[string]any, error) {
	if c.tun == nil {
		return nil, api.ErrNotSupported
	}
	c.tun.checkExit(ctx, "button")
	c.checkSysProxy(ctx, "button")
	return c.tun.status(), nil
}
