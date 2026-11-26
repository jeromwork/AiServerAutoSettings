//go:build linux

package platform

import (
	"context"
	"os"
	"syscall"
)

// WatchNet — события смены сети из netlink (адреса, линки, маршруты IPv4/IPv6). Канал с буфером 1:
// события сливаются, медленный читатель не блокирует сторож. Закрывается при ctx.Done или ошибке сокета.
func WatchNet(ctx context.Context) <-chan struct{} {
	out := make(chan struct{}, 1)
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC|syscall.SOCK_NONBLOCK, syscall.NETLINK_ROUTE)
	if err != nil {
		close(out)
		return out
	}
	const groups = 0x1 | 0x10 | 0x40 | 0x100 | 0x400 // LINK, IPV4_IFADDR, IPV4_ROUTE, IPV6_IFADDR, IPV6_ROUTE
	if err = syscall.Bind(fd, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK, Groups: groups}); err != nil {
		_ = syscall.Close(fd)
		close(out)
		return out
	}
	f := os.NewFile(uintptr(fd), "netlink")
	go func() { <-ctx.Done(); _ = f.Close() }()
	go func() {
		defer close(out)
		buf := make([]byte, 1<<16)
		for {
			n, err := f.Read(buf) // блокирует на poller; Close будит
			if err != nil {
				return
			}
			if n > 0 {
				select {
				case out <- struct{}{}:
				default:
				}
			}
		}
	}()
	return out
}
