//go:build windows

package platform

import (
	"errors"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var iphlpapi = windows.NewLazySystemDLL("iphlpapi.dll")
var notifyInterface = iphlpapi.NewProc("NotifyIpInterfaceChange")
var notifyRoute = iphlpapi.NewProc("NotifyRouteChange2")
var cancelNotify = iphlpapi.NewProc("CancelMibChangeNotify2")

// One process-wide callback: NewCallback slots cannot be freed by Go.
var watches = struct {
	sync.Mutex
	next  uintptr
	items map[uintptr]*NetWatch
}{items: make(map[uintptr]*NetWatch)}

var notifyCallback = syscall.NewCallback(func(id, row uintptr, kind uint32) uintptr {
	watches.Lock()
	w := watches.items[id]
	watches.Unlock()
	if w != nil {
		w.changed()
	}
	return 0
})

func (w *NetWatch) watch() (func() error, error) {
	watches.Lock()
	watches.next++
	id := watches.next
	watches.items[id] = w
	watches.Unlock()
	var handles []windows.Handle
	var failures []error
	for _, proc := range []*windows.LazyProc{notifyInterface, notifyRoute} {
		var h windows.Handle
		rc, _, _ := proc.Call(0, notifyCallback, id, 0, uintptr(unsafe.Pointer(&h)))
		if rc != 0 {
			err := syscall.Errno(rc)
			failures = append(failures, err)
			if w.log != nil {
				w.log.Warn("netwatch.register.failed", "fn", proc.Name, "code", rc)
			}
		} else {
			handles = append(handles, h)
		}
	}
	close := func() error {
		var errs []error
		for _, h := range handles {
			rc, _, _ := cancelNotify.Call(uintptr(h))
			if rc != 0 {
				errs = append(errs, syscall.Errno(rc))
			}
		}
		watches.Lock()
		delete(watches.items, id)
		watches.Unlock()
		return errors.Join(errs...)
	}
	if len(handles) == 0 {
		_ = close()
		return nil, errors.Join(failures...)
	}
	if w.log != nil {
		w.log.Info("netwatch.ready", "handles", len(handles))
	}
	return close, nil
}
