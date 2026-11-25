package core

import (
	"golang.org/x/sys/windows"
	"unsafe"
)

var getMemory = windows.NewLazySystemDLL("psapi.dll").NewProc("GetProcessMemoryInfo")

func rssBytes() uint64 {
	var m struct {
		Size, Faults                                                                uint32
		Peak, RSS, PeakPaged, Paged, PeakNonPaged, NonPaged, Pagefile, PeakPagefile uintptr
	}
	m.Size = uint32(unsafe.Sizeof(m))
	ok, _, _ := getMemory.Call(uintptr(windows.CurrentProcess()), uintptr(unsafe.Pointer(&m)), uintptr(m.Size))
	if ok == 0 {
		return 0
	}
	return uint64(m.RSS)
}
