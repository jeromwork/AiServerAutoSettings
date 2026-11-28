//go:build windows

package main

import "golang.org/x/sys/windows"

// showError показывает окно с причиной: консоль может закрыться, а владелец должен увидеть сбой.
func showError(msg string) {
	t, err1 := windows.UTF16PtrFromString("RemoteAgents")
	m, err2 := windows.UTF16PtrFromString(msg)
	if err1 != nil || err2 != nil {
		return
	}
	// MB_OK | MB_ICONERROR | MB_SETFOREGROUND | MB_TOPMOST
	_, _ = windows.MessageBox(0, m, t, 0x10|0x10000|0x40000)
}

// showInfo — информационное окно с итогом действия (меню Проводника).
func showInfo(msg string) {
	t, err1 := windows.UTF16PtrFromString("RemoteAgents")
	m, err2 := windows.UTF16PtrFromString(msg)
	if err1 != nil || err2 != nil {
		return
	}
	// MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND | MB_TOPMOST
	_, _ = windows.MessageBox(0, m, t, 0x40|0x10000|0x40000)
}
