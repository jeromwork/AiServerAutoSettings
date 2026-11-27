//go:build darwin

package platform

import (
	"net"
	"strings"
)

// isHardwareIface — на macOS «не железные» это utun*/ipsec*/ppp*/tun*/tap*.
func isHardwareIface(ni net.Interface) bool {
	for _, p := range []string{"utun", "ipsec", "ppp", "tun", "tap"} {
		if strings.HasPrefix(ni.Name, p) {
			return false
		}
	}
	return true
}
