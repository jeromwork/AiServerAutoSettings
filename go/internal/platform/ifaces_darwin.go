//go:build darwin

package platform

import (
	"net"

	"remoteagents/internal/api"
)

// На macOS маршрут по умолчанию не разбирается: DefaultRoute=false → PhysicalInterface пуст, sing-box на auto_detect_interface.
func listIfaces() ([]api.Iface, error) {
	nis, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	var out []api.Iface
	for _, ni := range nis {
		f := api.Iface{Name: ni.Name, Up: ni.Flags&net.FlagUp != 0}
		if as, e := ni.Addrs(); e == nil {
			for _, a := range as {
				f.Addrs = append(f.Addrs, a.String())
			}
		}
		out = append(out, f)
	}
	return out, nil
}
