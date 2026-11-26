//go:build windows

package platform

import (
	"unsafe"

	"golang.org/x/sys/windows"

	"remoteagents/internal/api"
)

const gaaFlags = windows.GAA_FLAG_SKIP_ANYCAST | windows.GAA_FLAG_SKIP_MULTICAST | windows.GAA_FLAG_SKIP_DNS_SERVER | windows.GAA_FLAG_INCLUDE_GATEWAYS

// listIfaces: GetAdaptersAddresses — имя (FriendlyName, как у sing-box/net), описание, шлюз, метрика IPv4.
func listIfaces() ([]api.Iface, error) {
	size := uint32(16 << 10)
	var buf []byte
	for i := 0; i < 4; i++ {
		buf = make([]byte, size)
		err := windows.GetAdaptersAddresses(windows.AF_INET, gaaFlags, 0, (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0])), &size)
		if err == nil {
			break
		}
		if err != windows.ERROR_BUFFER_OVERFLOW {
			return nil, err
		}
	}
	var out []api.Iface
	for a := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0])); a != nil; a = a.Next {
		f := api.Iface{
			Name:         windows.UTF16PtrToString(a.FriendlyName),
			Desc:         windows.UTF16PtrToString(a.Description),
			Up:           a.OperStatus == 1 && a.IfType != 24, // IfOperStatusUp, не loopback
			DefaultRoute: a.FirstGatewayAddress != nil,
			Metric:       int(a.Ipv4Metric),
		}
		for u := a.FirstUnicastAddress; u != nil; u = u.Next {
			if ip := u.Address.IP(); ip != nil {
				f.Addrs = append(f.Addrs, ip.String())
			}
		}
		out = append(out, f)
	}
	return out, nil
}
