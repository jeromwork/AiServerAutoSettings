package platform

import (
	"encoding/binary"
	"net"
	"net/netip"
	"strconv"
	"strings"
)

// Route — запись таблицы маршрутов IPv4: префикс и имя интерфейса ("" — не определён).
type Route struct {
	Prefix netip.Prefix
	Iface  string
}

// ForeignMaxPrefix — наибольшая длина префикса публичных маршрутов ЧУЖИХ виртуальных адаптеров (не наших, не физических).
// Хостовые маршруты (/31, /32 — закрепление адреса сервера чужого VPN) не считаются: нарезкой их не перебить.
// 0 — таких маршрутов нет. Побеждает самый длинный префикс, поэтому наши блоки должны быть мельче этого значения.
func ForeignMaxPrefix(routes []Route) (int, string) {
	best, via := 0, ""
	for _, r := range routes {
		if !r.Prefix.IsValid() || !r.Prefix.Addr().Is4() || r.Iface == "" || isOurIface(r.Iface) || !IsVirtualIface(r.Iface, "") {
			continue
		}
		b := r.Prefix.Bits()
		if b > 30 || !publicV4(r.Prefix) {
			continue
		}
		if b > best {
			best, via = b, r.Iface
		}
	}
	return best, via
}

var nonPublicV4 = func() []netip.Prefix {
	var out []netip.Prefix
	for _, s := range []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "127.0.0.0/8", "224.0.0.0/4", "240.0.0.0/4"} {
		out = append(out, netip.MustParsePrefix(s))
	}
	return out
}()

// publicV4 — префикс не лежит целиком в частных/служебных диапазонах (те наши маршруты и так не перекрывают).
func publicV4(p netip.Prefix) bool {
	for _, n := range nonPublicV4 {
		if n.Contains(p.Addr()) && n.Bits() <= p.Bits() {
			return false
		}
	}
	return true
}

// ForeignRoutePrefix — ForeignMaxPrefix по таблице маршрутов ОС; ошибка чтения — (0, "").
func ForeignRoutePrefix() (int, string) {
	rs, err := readRoutes()
	if err != nil {
		return 0, ""
	}
	return ForeignMaxPrefix(rs)
}

func maskBits(mask string) (int, bool) {
	ip := net.ParseIP(mask).To4()
	if ip == nil {
		return 0, false
	}
	ones, bits := net.IPMask(ip).Size()
	return ones, bits == 32
}

// parseWinRoutePrint — вывод `route print -4`: «Network Destination, Netmask, Gateway, Interface(IP), Metric».
// ifName переводит локальный IP интерфейса в его имя.
func parseWinRoutePrint(out string, ifName func(netip.Addr) string) []Route {
	var rs []Route
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) != 5 {
			continue
		}
		if _, err := strconv.Atoi(f[4]); err != nil {
			continue
		}
		dst, err1 := netip.ParseAddr(f[0])
		ifa, err2 := netip.ParseAddr(f[3])
		bits, ok := maskBits(f[1])
		if err1 != nil || err2 != nil || !ok || !dst.Is4() {
			continue
		}
		p, err := dst.Prefix(bits)
		if err != nil {
			continue
		}
		rs = append(rs, Route{Prefix: p, Iface: ifName(ifa)})
	}
	return rs
}

// parseProcNetRoute — /proc/net/route (Linux): Iface Destination Gateway Flags RefCnt Use Metric Mask, адреса — little-endian hex.
func parseProcNetRoute(data string) []Route {
	var rs []Route
	for i, line := range strings.Split(data, "\n") {
		f := strings.Fields(line)
		if i == 0 || len(f) < 8 {
			continue
		}
		d, e1 := strconv.ParseUint(f[1], 16, 32)
		m, e2 := strconv.ParseUint(f[7], 16, 32)
		fl, e3 := strconv.ParseUint(f[3], 16, 32)
		if e1 != nil || e2 != nil || e3 != nil || fl&1 == 0 { // RTF_UP
			continue
		}
		var db, mb [4]byte
		binary.LittleEndian.PutUint32(db[:], uint32(d))
		binary.LittleEndian.PutUint32(mb[:], uint32(m))
		ones, bits := net.IPMask(mb[:]).Size()
		if bits != 32 {
			continue
		}
		p, err := netip.AddrFrom4(db).Prefix(ones)
		if err != nil {
			continue
		}
		rs = append(rs, Route{Prefix: p, Iface: f[0]})
	}
	return rs
}

// parseDarwinNetstat — `netstat -rn -f inet` (macOS): «Destination Gateway Flags Netif …», адреса сокращены («10/8», «1.2.3», «default»).
func parseDarwinNetstat(out string) []Route {
	var rs []Route
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		p, ok := darwinDest(f[0])
		if !ok {
			continue
		}
		rs = append(rs, Route{Prefix: p, Iface: f[3]})
	}
	return rs
}

func darwinDest(s string) (netip.Prefix, bool) {
	if s == "default" {
		return netip.MustParsePrefix("0.0.0.0/0"), true
	}
	addr, mask, hasMask := strings.Cut(s, "/")
	if strings.ContainsAny(addr, ":%") {
		return netip.Prefix{}, false
	}
	parts := strings.Split(addr, ".")
	if len(parts) == 0 || len(parts) > 4 {
		return netip.Prefix{}, false
	}
	octets := 0
	var b [4]byte
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 || n > 255 {
			return netip.Prefix{}, false
		}
		b[i] = byte(n)
		octets++
	}
	bits := octets * 8
	if hasMask {
		n, err := strconv.Atoi(mask)
		if err != nil || n < 0 || n > 32 {
			return netip.Prefix{}, false
		}
		bits = n
	}
	p, err := netip.AddrFrom4(b).Prefix(bits)
	return p, err == nil
}
