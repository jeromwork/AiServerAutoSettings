//go:build windows

package platform

import (
	"context"
	"strings"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"

	"remoteagents/internal/api"
)

const inetSettingsKey = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`

// SystemProxy — HKCU\...\Internet Settings: ProxyEnable, ProxyServer, AutoConfigURL (только чтение).
func SystemProxy() api.SysProxy {
	res := api.SysProxy{Supported: true}
	k, err := registry.OpenKey(registry.CURRENT_USER, inetSettingsKey, registry.QUERY_VALUE)
	if err != nil {
		return res
	}
	defer k.Close()
	if v, _, e := k.GetIntegerValue("ProxyEnable"); e == nil && v != 0 {
		if s, _, e := k.GetStringValue("ProxyServer"); e == nil && strings.TrimSpace(s) != "" {
			res.Enabled, res.Server = true, strings.TrimSpace(s)
		}
	}
	if s, _, e := k.GetStringValue("AutoConfigURL"); e == nil && strings.TrimSpace(s) != "" {
		res.Enabled, res.PAC = true, strings.TrimSpace(s)
	}
	return res
}

// WatchSysProxy — RegNotifyChangeKeyValue на ключе Internet Settings (событие реестра, без опроса). Канал с буфером 1,
// события сливаются; закрывается с ctx. Нет доступа к ключу — канал просто ждёт ctx.
func WatchSysProxy(ctx context.Context) <-chan struct{} {
	out := make(chan struct{}, 1)
	go func() {
		defer close(out)
		k, err := registry.OpenKey(registry.CURRENT_USER, inetSettingsKey, registry.NOTIFY|registry.QUERY_VALUE)
		if err != nil {
			<-ctx.Done()
			return
		}
		defer k.Close()
		ev, err := windows.CreateEvent(nil, 0, 0, nil) // автосброс
		if err != nil {
			<-ctx.Done()
			return
		}
		defer windows.CloseHandle(ev)
		stop, err := windows.CreateEvent(nil, 1, 0, nil)
		if err != nil {
			<-ctx.Done()
			return
		}
		defer windows.CloseHandle(stop)
		go func() { <-ctx.Done(); _ = windows.SetEvent(stop) }()
		for {
			if err := windows.RegNotifyChangeKeyValue(windows.Handle(k), false,
				windows.REG_NOTIFY_CHANGE_LAST_SET|windows.REG_NOTIFY_CHANGE_NAME, ev, true); err != nil {
				<-ctx.Done()
				return
			}
			r, _ := windows.WaitForMultipleObjects([]windows.Handle{ev, stop}, false, windows.INFINITE)
			if r != windows.WAIT_OBJECT_0 {
				return
			}
			select {
			case out <- struct{}{}:
			default:
			}
		}
	}()
	return out
}
