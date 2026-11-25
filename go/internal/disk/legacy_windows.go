package disk

import (
	"context"
	"crypto/sha256"
	"encoding/csv"
	"fmt"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"golang.org/x/sys/windows"
)

func (d *Disk) foreignRunning(ctx context.Context) bool {
	out, _, _, e := d.command(ctx, "disk.foreign", "tasklist", []string{"/FO", "CSV", "/NH"}, 10*time.Second)
	if e != nil {
		return false
	}
	records, _ := csv.NewReader(strings.NewReader(strings.ToLower(string(out)))).ReadAll()
	for _, row := range records {
		if len(row) > 0 && (row[0] == "syncthingtray.exe" || row[0] == "syncthing.exe") {
			return true
		}
	}
	return false
}
func engineLock(home string) (func(), error) {
	key, e := filepath.Abs(home)
	if e != nil {
		return nil, e
	}
	key = strings.ToLower(strings.TrimRight(strings.ReplaceAll(key, "/", `\`), `\`))
	hash := sha256.Sum256([]byte(key))
	name, e := windows.UTF16PtrFromString(fmt.Sprintf(`Global\RemoteDiskEngine-%X`, hash))
	if e != nil {
		return nil, e
	}
	// A Windows mutex belongs to the OS thread that acquired it.
	runtime.LockOSThread()
	h, e := windows.CreateMutex(nil, false, name)
	if e != nil && e != windows.ERROR_ALREADY_EXISTS {
		runtime.UnlockOSThread()
		return nil, e
	}
	status, e := windows.WaitForSingleObject(h, 0)
	if e != nil || status != windows.WAIT_OBJECT_0 && status != windows.WAIT_ABANDONED {
		windows.CloseHandle(h)
		runtime.UnlockOSThread()
		return nil, fmt.Errorf("Диск занят Программой")
	}
	return func() { _ = windows.ReleaseMutex(h); _ = windows.CloseHandle(h); runtime.UnlockOSThread() }, nil
}
func isJunction(path string) bool {
	p, e := windows.UTF16PtrFromString(path)
	if e != nil {
		return false
	}
	attributes, e := windows.GetFileAttributes(p)
	return e == nil && attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0
}
