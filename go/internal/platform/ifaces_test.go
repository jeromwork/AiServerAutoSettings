package platform

import (
	"testing"

	"remoteagents/internal/api"
)

func ifc(name, desc string, def bool, metric int, addr string) api.Iface {
	return api.Iface{Name: name, Desc: desc, Up: true, DefaultRoute: def, Metric: metric, Addrs: []string{addr}}
}

// Чужой TUN стал маршрутом по умолчанию с лучшей метрикой — выбираем физический.
func TestPickPhysicalSkipsForeignTun(t *testing.T) {
	ifs := []api.Iface{
		ifc("happ-tun", "Wintun Userspace Tunnel", true, 1, "10.0.0.2"),
		ifc("Tailscale", "Tailscale Tunnel", true, 1, "100.64.1.2"),
		ifc("vEthernet (Default Switch)", "Hyper-V Virtual Ethernet Adapter", true, 5, "172.20.0.1"),
		ifc("RA2-LAN", "Wintun", true, 2, "172.19.0.1"),
		ifc("Wi-Fi", "Intel(R) Wi-Fi 6 AX201", true, 35, "192.168.1.10"),
		ifc("Ethernet", "Realtek PCIe GbE", true, 25, "192.168.1.11"),
	}
	if got := PickPhysical(ifs); got != "Ethernet" {
		t.Fatalf("got %q", got)
	}
	ifs[5].Up = false
	if got := PickPhysical(ifs); got != "Wi-Fi" {
		t.Fatalf("got %q", got)
	}
}

func TestPickPhysicalNone(t *testing.T) {
	ifs := []api.Iface{ifc("Tailscale", "", true, 1, "100.64.1.2"), ifc("Wi-Fi", "", false, 10, "192.168.1.5"), ifc("Wi-Fi 2", "", true, 10, "169.254.1.1")}
	if got := PickPhysical(ifs); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestIsVirtual(t *testing.T) {
	for _, n := range []string{"tailscale0", "wg0", "docker0", "lo", "Loopback Pseudo-Interface 1", "ra3-abcd1234-vpn", "WSL (Hyper-V firewall)"} {
		if !IsVirtualIface(n, "") {
			t.Errorf("%s must be virtual", n)
		}
	}
	for _, n := range []string{"Wi-Fi", "Ethernet", "Ethernet 2", "eth0", "enp3s0", "wlan0", "en0"} {
		if IsVirtualIface(n, "Intel(R) Ethernet Controller") {
			t.Errorf("%s must be physical", n)
		}
	}
}
