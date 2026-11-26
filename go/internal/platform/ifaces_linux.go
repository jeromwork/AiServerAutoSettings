//go:build linux

package platform

import (
	"bufio"
	"net"
	"os"
	"strconv"
	"strings"

	"remoteagents/internal/api"
)

func listIfaces() ([]api.Iface, error) {
	nis, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	def := linuxDefaultRoutes("/proc/net/route")
	out := make([]api.Iface, 0, len(nis))
	for _, ni := range nis {
		f := api.Iface{Name: ni.Name, Up: ni.Flags&net.FlagUp != 0 && ni.Flags&net.FlagLoopback == 0}
		if as, e := ni.Addrs(); e == nil {
			for _, a := range as {
				f.Addrs = append(f.Addrs, a.String())
			}
		}
		if m, ok := def[ni.Name]; ok {
			f.DefaultRoute, f.Metric = true, m
		}
		out = append(out, f)
	}
	return out, nil
}

// linuxDefaultRoutes: интерфейс → метрика маршрута 0.0.0.0/0 из /proc/net/route.
func linuxDefaultRoutes(path string) map[string]int {
	res := map[string]int{}
	fh, err := os.Open(path)
	if err != nil {
		return res
	}
	defer fh.Close()
	sc := bufio.NewScanner(fh)
	sc.Scan() // заголовок
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 8 || f[1] != "00000000" || f[7] != "00000000" {
			continue
		}
		m, _ := strconv.Atoi(f[6])
		if old, ok := res[f[0]]; !ok || m < old {
			res[f[0]] = m
		}
	}
	return res
}
