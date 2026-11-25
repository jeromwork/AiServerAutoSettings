package forward

import (
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"strings"
	"time"
)

var tlsPorts = map[int]bool{443: true, 465: true, 636: true, 993: true, 995: true, 5986: true, 8443: true}
var httpPorts = map[int]bool{80: true, 8080: true, 8090: true}

const readMax = 4096

type lanState struct {
	name, target, status, detail string
	ms                           int64
	since                        time.Time
}

type lanTarget struct {
	name, host string
	port       int
}

// lanTargets: сети из lan[] с адресом проверки (testHost/testPort, иначе host/port, иначе 22).
func (f *fwd) lanTargets() []lanTarget {
	var out []lanTarget
	seen := map[string]bool{}
	for _, it := range f.cfg.LAN {
		host, port := it.TestHost, it.TestPort
		if host == "" {
			host = it.Host
		}
		if port == 0 {
			port = it.Port
		}
		if port == 0 {
			port = 22
		}
		if it.Name == "" || seen[it.Name] || !it.Share.Enabled || host == "" || port < 1 || port > 65535 {
			continue
		}
		seen[it.Name] = true
		out = append(out, lanTarget{it.Name, host, port})
		if len(out) == 64 {
			break
		}
	}
	return out
}

// startLan: на каждую сеть своя проверка через канал; обрыв канала закрывает сокеты и отменяет контекст.
func (f *fwd) startLan(ctx context.Context, session int) {
	if f.mode.Safe {
		return
	}
	ts := f.lanTargets()
	f.cmu.Lock()
	f.lan, f.lanOrd = map[string]*lanState{}, nil
	for _, t := range ts {
		f.lan[t.name] = &lanState{name: t.name, target: net.JoinHostPort(t.host, fmt.Sprint(t.port)), status: "checking", since: time.Now()}
		f.lanOrd = append(f.lanOrd, t.name)
	}
	f.cmu.Unlock()
	for _, t := range ts {
		go func() {
			st, detail, ms := f.check(ctx, t.host, t.port)
			f.cmu.Lock()
			s := f.lan[t.name]
			if f.session == session && f.up && s != nil { // канал не менялся
				s.status, s.detail, s.ms = st, detail, ms
			}
			f.cmu.Unlock()
			f.log.Info("lan.result", "name", t.name, "status", st, "detail", detail, "ms", ms)
		}()
	}
}

func (f *fwd) lanStatusLocked(now time.Time) []map[string]any {
	out := []map[string]any{}
	for _, n := range f.lanOrd {
		s := f.lan[n]
		d := map[string]any{"name": s.name, "target": s.target, "status": s.status, "detail": s.detail, "ms": s.ms}
		if s.status == "checking" {
			d["detail"] = fmt.Sprintf("нет ответа %d с", int(now.Sub(s.since).Seconds())) // показание часов, не таймер
		}
		out = append(out, d)
	}
	return out
}

func recvUntil(c net.Conn, done func([]byte) bool) []byte {
	var buf []byte
	tmp := make([]byte, 1024)
	for !done(buf) && len(buf) < readMax {
		n, err := c.Read(tmp)
		buf = append(buf, tmp[:n]...)
		if n == 0 || err != nil {
			break
		}
	}
	return buf
}

func firstLine(b []byte, max int) string {
	s := strings.TrimSpace(strings.SplitN(strings.SplitN(string(b), "\n", 2)[0], "\r", 2)[0])
	if len(s) > max {
		s = s[:max]
	}
	return s
}

// check -> (ok|refused|error, подробности, мс). Ответ цели: 22 — баннер SSH-, TLS-порты — рукопожатие TLS (сертификат не
// проверяется), 80/8080/8090 — первая строка HTTP/, остальные — успешное соединение.
func (f *fwd) check(ctx context.Context, host string, port int) (string, string, int64) {
	t0 := time.Now()
	ms := func() int64 { return time.Since(t0).Milliseconds() }
	f.cmu.Lock()
	up := f.sctx
	f.cmu.Unlock()
	if up == nil {
		return "error", "канал не работает", ms()
	}
	c, err := f.ch.DialContext(ctx, "tcp", net.JoinHostPort(host, fmt.Sprint(port)))
	if err != nil {
		e := err.Error()
		if strings.Contains(e, "refused") {
			return "refused", "отказ в соединении", ms()
		}
		if len(e) > 60 {
			e = e[:60]
		}
		return "error", e, ms()
	}
	f.track(c) // обрыв канала закрывает сокет
	defer func() {
		f.cmu.Lock()
		delete(f.conns, c)
		f.cmu.Unlock()
		c.Close()
	}()
	switch {
	case port == 22:
		b := recvUntil(c, func(x []byte) bool { return bytes.Contains(x, []byte("\n")) })
		if bytes.HasPrefix(b, []byte("SSH-")) {
			return "ok", "баннер " + firstLine(b, 40), ms()
		}
		if len(b) > 0 {
			return "error", "нет баннера SSH-", ms()
		}
		return "error", "закрыто без ответа", ms()
	case httpPorts[port]:
		c.Write([]byte("GET / HTTP/1.0\r\nHost: " + host + "\r\n\r\n"))
		b := recvUntil(c, func(x []byte) bool { return bytes.Contains(x, []byte("\n")) || len(x) >= 12 })
		if bytes.HasPrefix(b, []byte("HTTP/")) {
			return "ok", "ответ " + firstLine(b, 30), ms()
		}
		if len(b) > 0 {
			return "error", "ответ не HTTP", ms()
		}
		return "error", "закрыто без ответа", ms()
	case tlsPorts[port]:
		cfg := &tls.Config{InsecureSkipVerify: true}
		if net.ParseIP(host) == nil {
			cfg.ServerName = host
		}
		tc := tls.Client(c, cfg)
		if err := tc.HandshakeContext(ctx); err != nil {
			e := "TLS: " + err.Error()
			if len(e) > 44 {
				e = e[:44]
			}
			return "error", e, ms()
		}
		return "ok", "TLS " + tls.VersionName(tc.ConnectionState().Version), ms()
	}
	return "ok", "соединение установлено", ms()
}
