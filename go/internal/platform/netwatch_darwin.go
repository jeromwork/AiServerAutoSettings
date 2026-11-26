//go:build darwin

package platform

import "context"

// WatchNet на macOS — заглушка: событий нет (канал закрывается с ctx).
func WatchNet(ctx context.Context) <-chan struct{} {
	ch := make(chan struct{})
	go func() { <-ctx.Done(); close(ch) }()
	return ch
}
