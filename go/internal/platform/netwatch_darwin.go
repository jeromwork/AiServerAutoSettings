//go:build darwin

package platform

import (
	"context"
	"os"
	"syscall"
)

// WatchNet — события routing socket (AF_ROUTE): смена адресов, интерфейсов, маршрутов. Канал с буфером 1,
// события сливаются; закрывается при ctx.Done или ошибке сокета.
func WatchNet(ctx context.Context) <-chan struct{} {
	out := make(chan struct{}, 1)
	fd, err := syscall.Socket(syscall.AF_ROUTE, syscall.SOCK_RAW, 0)
	if err != nil {
		close(out)
		return out
	}
	syscall.CloseOnExec(fd)
	f := os.NewFile(uintptr(fd), "route")
	go func() { <-ctx.Done(); _ = f.Close() }()
	go func() {
		defer close(out)
		buf := make([]byte, 1<<16)
		for {
			n, err := f.Read(buf)
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
