package platform

import (
	"context"
	"remoteagents/internal/api"
	"remoteagents/internal/bus"
	"sync"
	"sync/atomic"
)

// NetWatch coalesces changes until the consumer calls Ack (v2 netwatch.py).
type NetWatch struct {
	bus     *bus.Bus
	log     api.Logger
	pending atomic.Bool
	mu      sync.Mutex
	close   func() error
}

func NewNetWatch(b *bus.Bus, log api.Logger) *NetWatch {
	w := &NetWatch{bus: b, log: log}
	b.Subscribe("app.start", func(bus.Event) {
		if err := w.Start(context.Background()); err != nil && log != nil {
			log.Error("netwatch.register.failed", "err", err)
		}
	})
	b.Subscribe("app.stop", func(bus.Event) { _ = w.Stop(context.Background()) })
	return w
}

func (w *NetWatch) Name() string { return "netwatch" }
func (w *NetWatch) Ack()         { w.pending.Store(false) }
func (w *NetWatch) changed() {
	if w.pending.CompareAndSwap(false, true) {
		w.bus.Publish("net.changed", nil)
	}
}
func (w *NetWatch) Start(context.Context) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.close != nil {
		return nil
	}
	close, err := w.watch()
	if err != nil {
		return err
	}
	w.close = close
	return nil
}
func (w *NetWatch) Stop(context.Context) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.close == nil {
		return nil
	}
	err := w.close()
	w.close = nil
	w.Ack()
	return err
}
func (w *NetWatch) Status() map[string]any {
	w.mu.Lock()
	defer w.mu.Unlock()
	return map[string]any{"running": w.close != nil, "pending": w.pending.Load()}
}
