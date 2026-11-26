package platform

import (
	"context"
	"testing"
	"time"
)

// Сторож закрывается вместе с контекстом (без утечки горутины и без опроса).
func TestWatchNetClosesWithContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	ch := WatchNet(ctx)
	cancel()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case _, ok := <-ch:
			if !ok {
				return
			}
		case <-deadline:
			t.Fatal("канал не закрылся")
		}
	}
}
