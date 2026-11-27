//go:build linux

package platform

import (
	"net"
	"os"
)

// isHardwareIface — у железного интерфейса есть /sys/class/net/<if>/device.
func isHardwareIface(ni net.Interface) bool {
	_, err := os.Stat("/sys/class/net/" + ni.Name + "/device")
	return err == nil
}
