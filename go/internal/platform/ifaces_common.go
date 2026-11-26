package platform

import (
	"net"
	"strings"

	"remoteagents/internal/api"
)

// virtualMarkers — признаки виртуальных/чужих адаптеров (имя или описание, нижний регистр).
// Выход sing-box привязывается только к физическому адаптеру, даже если чужой TUN стал маршрутом по умолчанию.
var virtualMarkers = []string{
	"tailscale", "happ", "wintun", "wireguard", "wg", "tap-", "tap ", "tun", "vethernet", "hyper-v", "wsl",
	"loopback", "vmware", "vmnet", "virtualbox", "vbox", "vpn", "ra2", "ra3-", "openvpn", "nordlynx", "zerotier",
	"docker", "veth", "virbr", "br-", "npcap", "pseudo", "teredo", "isatap", "6to4", "bluetooth", "utun", "awdl", "llw", "bridge",
}

// IsVirtualIface — адаптер виртуальный/чужой (Tailscale, happ-tun, RA2-LAN, Hyper-V, WSL, loopback, VPN других программ).
func IsVirtualIface(name, desc string) bool {
	for _, s := range []string{name, desc} {
		s = strings.ToLower(s)
		if s == "lo" || strings.HasPrefix(s, "lo ") {
			return true
		}
		for _, m := range virtualMarkers {
			if strings.Contains(s, m) {
				return true
			}
		}
	}
	return false
}

func usableV4(addrs []string) bool {
	for _, a := range addrs {
		if i := strings.IndexByte(a, '/'); i >= 0 {
			a = a[:i]
		}
		ip := net.ParseIP(a)
		if ip4 := ip.To4(); ip4 != nil && !ip4.IsLinkLocalUnicast() && !ip4.IsLoopback() && !ip4.IsUnspecified() {
			return true
		}
	}
	return false
}

// PickPhysical выбирает физический внешний интерфейс: поднят, невиртуальный, с маршрутом по умолчанию и рабочим IPv4;
// из нескольких — с меньшей метрикой (при равенстве — первый). "" — подходящего нет (sing-box остаётся на auto_detect_interface).
func PickPhysical(ifs []api.Iface) string {
	best, bm := "", 0
	for _, f := range ifs {
		if !f.Up || !f.DefaultRoute || IsVirtualIface(f.Name, f.Desc) || !usableV4(f.Addrs) {
			continue
		}
		if best == "" || f.Metric < bm {
			best, bm = f.Name, f.Metric
		}
	}
	return best
}

// PhysicalInterface — имя физического внешнего интерфейса сейчас ("" — не определён).
func PhysicalInterface() string {
	ifs, err := listIfaces()
	if err != nil {
		return ""
	}
	return PickPhysical(ifs)
}

// Interfaces — снимок адаптеров ПК.
func (p *stubPlatform) Interfaces() ([]api.Iface, error) { return listIfaces() }
