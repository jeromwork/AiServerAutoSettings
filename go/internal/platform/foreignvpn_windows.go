//go:build windows

package platform

import (
	"net"

	"golang.org/x/sys/windows"
)

const ifHardwareInterface = 0x1 // бит HardwareInterface в InterfaceAndOperStatusFlags

// isHardwareIface — GetIfEntry2Ex по индексу, бит HardwareInterface. Ошибка запроса — считаем железным (не уступаем зря).
func isHardwareIface(ni net.Interface) bool {
	var row windows.MibIfRow2
	row.InterfaceIndex = uint32(ni.Index)
	if err := windows.GetIfEntry2Ex(0, &row); err != nil {
		return true
	}
	return row.InterfaceAndOperStatusFlags&ifHardwareInterface != 0
}
