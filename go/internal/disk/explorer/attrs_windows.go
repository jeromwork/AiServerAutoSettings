//go:build windows

package explorer

import (
	"os"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const (
	attrReadOnly = 0x1
	attrHidden   = 0x2
	attrSystem   = 0x4
	attrReparse  = 0x400
)

func getAttrs(path string, _ os.FileInfo) Attrs {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return Attrs{}
	}
	v, err := windows.GetFileAttributes(p)
	if err != nil {
		return Attrs{}
	}
	return Attrs{ReadOnly: v&attrReadOnly != 0, Hidden: v&attrHidden != 0, System: v&attrSystem != 0, Reparse: v&attrReparse != 0}
}

func setAttrs(path string, a Attrs) error {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	cur, err := windows.GetFileAttributes(p)
	if err != nil {
		return err
	}
	v := cur &^ (attrReadOnly | attrHidden | attrSystem)
	if a.ReadOnly {
		v |= attrReadOnly
	}
	if a.Hidden {
		v |= attrHidden
	}
	if a.System {
		v |= attrSystem
	}
	if v == 0 {
		v = windows.FILE_ATTRIBUTE_NORMAL
	}
	if v == cur {
		return nil
	}
	return windows.SetFileAttributes(p, v)
}

var (
	shell32          = windows.NewLazySystemDLL("shell32.dll")
	procChangeNotify = shell32.NewProc("SHChangeNotify")
	procFileOp       = shell32.NewProc("SHFileOperationW")
)

func shChange(ev, flags uintptr, a, b *uint16) {
	_, _, _ = procChangeNotify.Call(ev, flags, uintptr(unsafe.Pointer(a)), uintptr(unsafe.Pointer(b)))
}

type notifier struct{}

// NewNotifier — SHChangeNotify для обновления значков.
func NewNotifier() Notifier { return notifier{} }

func (notifier) Changed(path string) {
	if p, err := windows.UTF16PtrFromString(path); err == nil {
		shChange(0x2000, 0x2005, p, nil) // SHCNE_UPDATEITEM, SHCNF_PATHW|FLUSHNOWAIT
	}
	dir := path
	for i := len(dir) - 1; i > 0; i-- {
		if dir[i] == '\\' || dir[i] == '/' {
			dir = dir[:i]
			break
		}
	}
	if p, err := windows.UTF16PtrFromString(dir); err == nil {
		shChange(0x1000, 0x2005, p, nil) // SHCNE_UPDATEDIR
	}
}

// AssociationsChanged — SHCNE_ASSOCCHANGED: Проводник перечитывает пункты меню.
func AssociationsChanged() { shChange(0x08000000, 0, nil, nil) }

type regStore struct{}

// NewRegStore — HKCU.
func NewRegStore() RegStore { return regStore{} }

func (regStore) Exists(key string) bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, key, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	k.Close()
	return true
}

func (regStore) Read(key, name string) string {
	k, err := registry.OpenKey(registry.CURRENT_USER, key, registry.QUERY_VALUE)
	if err != nil {
		return ""
	}
	defer k.Close()
	v, _, err := k.GetStringValue(name)
	if err != nil {
		return ""
	}
	return v
}

func (regStore) Write(key, name, value string) error {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, key, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	return k.SetStringValue(name, value)
}

func (regStore) DeleteTree(key string) error {
	// Вложенный \command удаляем раньше родителя.
	_ = registry.DeleteKey(registry.CURRENT_USER, key+`\command`)
	err := registry.DeleteKey(registry.CURRENT_USER, key)
	if err == registry.ErrNotExist || err == syscall.ERROR_FILE_NOT_FOUND {
		return nil
	}
	return err
}

// SHFILEOPSTRUCTW; на amd64/arm64 выравнивание полей даёт обычный порядок Go-структуры.
type shFileOp struct {
	Hwnd                 windows.Handle
	Func                 uint32
	From, To             *uint16
	Flags                uint16
	AnyOperationsAborted int32
	NameMappings         uintptr
	ProgressTitle        *uint16
}

// RecycleBin переносит папку в Корзину. Только фиксированные диски; ALLOWUNDO без NOCONFIRMATION и с WANTNUKEWARNING:
// если Корзина не примет, Проводник спросит, и отказ вернёт ошибку. Затем проверяем, что папки больше нет.
// Удаление навсегда в обход Корзины не делается.
func RecycleBin(path string) error {
	root := path
	if v := windows.StringToUTF16Ptr(path); v != nil {
		var buf [windows.MAX_PATH + 1]uint16
		if err := windows.GetVolumePathName(v, &buf[0], uint32(len(buf))); err == nil {
			root = windows.UTF16ToString(buf[:])
		}
	}
	if windows.GetDriveType(windows.StringToUTF16Ptr(root)) != windows.DRIVE_FIXED {
		return ErrRecycle
	}
	from, err := windows.UTF16FromString(path)
	if err != nil {
		return ErrRecycle
	}
	from = append(from, 0) // двойной ноль
	const (
		foDelete        = 3
		fofAllowUndo    = 0x40
		fofWantNukeWarn = 0x4000
	)
	op := shFileOp{Func: foDelete, From: &from[0], Flags: fofAllowUndo | fofWantNukeWarn}
	r, _, _ := procFileOp.Call(uintptr(unsafe.Pointer(&op)))
	if r != 0 || op.AnyOperationsAborted != 0 {
		return ErrRecycle
	}
	if _, err := os.Lstat(path); err == nil {
		return ErrRecycle
	}
	return nil
}
