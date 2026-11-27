//go:build windows

// Package wincon — работа с консолью Windows для exe без окна (-H windowsgui):
// у сторожа консоли нет, у ядра она скрытая, мягкая остановка идёт через Ctrl+Break в консоль ядра.
package wincon

import (
	"os"
	"sync"
	"syscall"

	"golang.org/x/sys/windows"
)

var (
	k32               = windows.NewLazySystemDLL("kernel32.dll")
	pAttachConsole    = k32.NewProc("AttachConsole")
	pAllocConsole     = k32.NewProc("AllocConsole")
	pFreeConsole      = k32.NewProc("FreeConsole")
	pGetConsoleWindow = k32.NewProc("GetConsoleWindow")
	pSetConsoleCtrl   = k32.NewProc("SetConsoleCtrlHandler")
	u32               = windows.NewLazySystemDLL("user32.dll")
	pShowWindow       = u32.NewProc("ShowWindow")
	breakMu           sync.Mutex
)

const attachParentProcess = ^uint32(0) // ATTACH_PARENT_PROCESS = (DWORD)-1

func hasConsole() bool {
	w, _, _ := pGetConsoleWindow.Call()
	return w != 0
}

// AttachParent подключает вывод к консоли родителя (запуск CLI из cmd): без неё exe -H windowsgui «немой».
// Уже перенаправленные дескрипторы (труба, файл) не трогаются.
func AttachParent() {
	if r, _, _ := pAttachConsole.Call(uintptr(attachParentProcess)); r == 0 {
		return
	}
	fix := func(f **os.File, name string, std uint32) {
		if h, err := windows.GetStdHandle(std); err == nil && h != 0 && h != windows.InvalidHandle {
			return
		}
		p, _ := windows.UTF16PtrFromString(name)
		h, err := windows.CreateFile(p, windows.GENERIC_READ|windows.GENERIC_WRITE,
			windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
		if err != nil {
			return
		}
		_ = windows.SetStdHandle(std, h)
		*f = os.NewFile(uintptr(h), name)
	}
	fix(&os.Stdin, "CONIN$", windows.STD_INPUT_HANDLE)
	fix(&os.Stdout, "CONOUT$", windows.STD_OUTPUT_HANDLE)
	fix(&os.Stderr, "CONOUT$", windows.STD_ERROR_HANDLE)
}

// HiddenConsole создаёт скрытую консоль (если её нет): ядру и его детям нужна консоль для Ctrl+Break.
// Родитель запускает ядро с HideWindow (SW_HIDE в STARTUPINFO), так что вспышки быть не должно;
// на всякий случай окно прячется и явно.
func HiddenConsole() {
	if hasConsole() {
		return
	}
	if r, _, _ := pAllocConsole.Call(); r == 0 {
		return
	}
	if w, _, _ := pGetConsoleWindow.Call(); w != 0 {
		_, _, _ = pShowWindow.Call(w, 0) // SW_HIDE
	}
}

// SendBreak шлёт Ctrl+Break группе процесса pid. Из процесса без консоли (сторож) на миг подключается
// к консоли цели. Возвращает false, если не вышло (вызывающий жёстко завершает процесс по сроку).
func SendBreak(pid uint32) bool {
	if hasConsole() {
		return windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, pid) == nil
	}
	breakMu.Lock()
	defer breakMu.Unlock()
	if r, _, _ := pAttachConsole.Call(uintptr(pid)); r == 0 {
		return false
	}
	_, _, _ = pSetConsoleCtrl.Call(0, 1) // сами игнорируем событие
	err := windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, pid)
	_, _, _ = pFreeConsole.Call()
	_, _, _ = pSetConsoleCtrl.Call(0, 0)
	return err == nil
}

// HiddenAttr — атрибуты запуска служебной консольной программы без окна.
func HiddenAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
}
