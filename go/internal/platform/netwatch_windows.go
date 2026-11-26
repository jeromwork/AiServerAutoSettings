//go:build windows

package platform

import (
	"context"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Системные уведомления IP Helper: смена интерфейсов, адресов, маршрутов. Без опроса.
var (
	iphlpapi      = windows.NewLazySystemDLL("iphlpapi.dll")
	pNotifyIf     = iphlpapi.NewProc("NotifyIpInterfaceChange")
	pNotifyRoute  = iphlpapi.NewProc("NotifyRouteChange2")
	pNotifyAddr   = iphlpapi.NewProc("NotifyUnicastIpAddressChange")
	pCancelNotify = iphlpapi.NewProc("CancelMibChangeNotify2")
	cbOnce        sync.Once
	cb            uintptr
	subMu         sync.Mutex
	subs          = map[int]chan struct{}{}
	subSeq        int
)

func fanout(_, _, _ uintptr) uintptr {
	subMu.Lock()
	for _, ch := range subs {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
	subMu.Unlock()
	return 0
}

// WatchNet — события смены сети (интерфейсы/адреса/маршруты). Канал с буфером 1, события сливаются; закрывается с ctx.
func WatchNet(ctx context.Context) <-chan struct{} {
	out := make(chan struct{}, 1)
	cbOnce.Do(func() { cb = syscall.NewCallback(fanout) }) // слот callback не освобождается: создаём один на процесс
	subMu.Lock()
	subSeq++
	id := subSeq
	subs[id] = out
	subMu.Unlock()
	var hs []uintptr
	reg := func(p *windows.LazyProc, args ...uintptr) {
		var h uintptr
		a := append(args, uintptr(unsafe.Pointer(&h)))
		if r, _, _ := p.Call(a...); r == 0 {
			hs = append(hs, h)
		}
	}
	// (Family, Callback, Context, InitialNotification, *Handle); NotifyRouteChange2 — то же.
	reg(pNotifyIf, 0, cb, 0, 0)
	reg(pNotifyRoute, 0, cb, 0, 0)
	reg(pNotifyAddr, 0, cb, 0, 0)
	go func() {
		<-ctx.Done()
		for _, h := range hs {
			_, _, _ = pCancelNotify.Call(h)
		}
		subMu.Lock()
		delete(subs, id)
		subMu.Unlock()
		close(out)
	}()
	return out
}
