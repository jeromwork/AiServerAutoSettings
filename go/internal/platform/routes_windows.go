//go:build windows

package platform

import (
	"context"
	"net"
	"net/netip"
	"os/exec"
	"syscall"
	"time"
)

func readRoutes() ([]Route, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "route", "print", "-4")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	byIP := map[netip.Addr]string{}
	if nis, e := net.Interfaces(); e == nil {
		for _, ni := range nis {
			as, _ := ni.Addrs()
			for _, a := range as {
				if ipn, ok := a.(*net.IPNet); ok {
					if ad, ok := netip.AddrFromSlice(ipn.IP); ok {
						byIP[ad.Unmap()] = ni.Name
					}
				}
			}
		}
	}
	return parseWinRoutePrint(string(out), func(a netip.Addr) string { return byIP[a] }), nil
}
