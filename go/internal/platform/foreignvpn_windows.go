//go:build windows

package platform

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

const ifHardwareInterface = 0x1 // бит HardwareInterface в InterfaceAndOperStatusFlags

// ForeignVPN — интерфейс, которым ОС ведёт трафик к 1.1.1.1 (GetBestInterfaceEx); железный и наш = "".
func ForeignVPN() string {
	var idx uint32
	sa := &windows.SockaddrInet4{Addr: [4]byte{1, 1, 1, 1}}
	if err := windows.GetBestInterfaceEx(sa, &idx); err != nil || idx == 0 {
		return ""
	}
	var row windows.MibIfRow2
	row.InterfaceIndex = idx
	if err := windows.GetIfEntry2Ex(0, &row); err != nil {
		return ""
	}
	if row.InterfaceAndOperStatusFlags&ifHardwareInterface != 0 {
		return ""
	}
	name := windows.UTF16ToString(row.Alias[:])
	if name == "" {
		name = windows.UTF16ToString((*[256]uint16)(unsafe.Pointer(&row.Description))[:])
	}
	if isOurIface(name) {
		return ""
	}
	return name
}
