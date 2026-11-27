package core

import (
	"context"
	"net/url"
	"strings"
	"sync/atomic"
	"time"

	"remoteagents/internal/platform"
)

// sysProxyState — системный прокси ПК и выход через него. Браузеры ходят через такой прокси мимо нашего TUN
// (Clash в режиме «системный прокси»): перекрыть нельзя, только показать. Прокси ПК мы только читаем.
type sysProxyState struct {
	Enabled   bool     `json:"enabled"`
	Server    string   `json:"server,omitempty"`
	PAC       string   `json:"pac,omitempty"`
	Local     bool     `json:"local"` // прокси на этом же ПК (127.0.0.1/localhost)
	Supported bool     `json:"supported"`
	IP        string   `json:"ip,omitempty"` // выход через прокси
	OK        bool     `json:"ok"`           // IP входит в ожидаемые адреса
	Known     bool     `json:"known"`
	Expected  []string `json:"expected,omitempty"`
	Err       string   `json:"error,omitempty"`
	At        string   `json:"at"`
	Reason    string   `json:"reason,omitempty"`
}

type sysProxyGuard struct {
	busy  atomic.Bool
	state atomic.Value // sysProxyState
}

// parseProxyServer — ProxyServer из ОС → URL прокси для проверки выхода. "h:p" и "http=h:p;https=h:p" → http://, "socks=h:p" → socks5://.
// Приоритет: https, http, socks. Пусто/непонятно — nil.
func parseProxyServer(s string) *url.URL {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	m := map[string]string{}
	if !strings.Contains(s, "=") {
		m["http"] = s
	} else {
		for _, part := range strings.FieldsFunc(s, func(r rune) bool { return r == ';' || r == ' ' }) {
			if k, v, ok := strings.Cut(part, "="); ok {
				m[strings.ToLower(k)] = v
			}
		}
	}
	for _, k := range []string{"https", "http", "socks"} {
		v := strings.TrimSpace(m[k])
		if v == "" {
			continue
		}
		scheme := "http"
		if k == "socks" {
			scheme = "socks5"
		}
		if i := strings.Index(v, "://"); i >= 0 {
			v = v[i+3:]
		}
		if u, err := url.Parse(scheme + "://" + v); err == nil && u.Host != "" {
			return u
		}
	}
	return nil
}

func isLocalHost(h string) bool {
	h = strings.ToLower(h)
	return h == "localhost" || h == "::1" || h == "[::1]" || strings.HasPrefix(h, "127.")
}

// sysProxyStatus — последнее состояние для страницы (nil — ещё не проверялось).
func (c *core) sysProxyStatus() any {
	if s, ok := c.sysp.state.Load().(sysProxyState); ok {
		return s
	}
	return nil
}

// checkSysProxy — прочитать системный прокси и, если включён, проверить выход через него. По событию (реестр/net-changed/кнопка);
// уже идущую проверку не дублирует. Результат — в снимок статуса и SSE "sysproxy".
func (c *core) checkSysProxy(ctx context.Context, reason string) {
	if !c.sysp.busy.CompareAndSwap(false, true) {
		return
	}
	defer c.sysp.busy.Store(false)
	sp := c.plat.SystemProxy()
	st := sysProxyState{Enabled: sp.Enabled, Server: sp.Server, PAC: sp.PAC, Supported: sp.Supported,
		At: time.Now().Format(time.RFC3339), Reason: reason}
	if u := parseProxyServer(sp.Server); u != nil {
		st.Local = isLocalHost(u.Hostname())
		st.Expected = expectedExitIPs(c.cfg)
		st.Known = len(st.Expected) > 0
		ip, _, err := fetchExitIPVia(ctx, u)
		if err != nil {
			st.Err = sanitize(err.Error())
		} else {
			st.IP = ip
			for _, x := range st.Expected {
				if x == ip {
					st.OK = true
				}
			}
		}
	}
	prev, had := c.sysp.state.Load().(sysProxyState)
	c.sysp.state.Store(st)
	if had && prev.Enabled == st.Enabled && prev.Server == st.Server && prev.PAC == st.PAC && prev.IP == st.IP && prev.Err == st.Err && reason != "button" {
		return
	}
	c.log.Info("sysproxy", "enabled", st.Enabled, "server", st.Server, "pac", st.PAC, "ip", st.IP, "ok", st.OK, "reason", reason)
	c.publish("sysproxy", st)
	c.publishStatus()
}

// watchSysProxy — событие реестра (Windows) → пересчёт; сразу при старте одна проверка. Таймеров нет.
func (c *core) watchSysProxy(ctx context.Context) {
	go c.checkSysProxy(ctx, "start")
	for range debounce(ctx, platform.WatchSysProxy(ctx), 300*time.Millisecond) {
		go c.checkSysProxy(ctx, "sysproxy-changed")
	}
}
