package channel

import (
	"sync"
	"time"
)

const sbCheckGap = 5 * time.Second // не чаще одной проверки по событиям журнала sing-box

// registry — живые ssh-соединения канала (для счётчика в /state и уборки забытых).
type registry struct {
	mu    sync.Mutex
	conns map[*conn]struct{}
	timer *time.Timer
}

func (c *chn) register(k *conn) {
	k.born = time.Now()
	k.owner = c
	c.reg.mu.Lock()
	if c.reg.conns == nil {
		c.reg.conns = map[*conn]struct{}{}
	}
	c.reg.conns[k] = struct{}{}
	n := len(c.reg.conns)
	c.reg.mu.Unlock()
	switch {
	case n > 2:
		go c.reap(0, n)
	case n > 1:
		c.armLeakCheck()
	}
}

func (c *chn) unregister(k *conn) {
	c.reg.mu.Lock()
	delete(c.reg.conns, k)
	c.reg.mu.Unlock()
}

// Sessions — число живых ssh-соединений канала: норма 1, во время переключения <= 2.
func (c *chn) Sessions() int {
	c.reg.mu.Lock()
	defer c.reg.mu.Unlock()
	return len(c.reg.conns)
}

// armLeakCheck — одноразовая страховка: если через время установки второе соединение так и не стало текущим — это утечка.
func (c *chn) armLeakCheck() {
	grace := c.o.DialTimeout + upTimeout + 5*time.Second
	c.reg.mu.Lock()
	defer c.reg.mu.Unlock()
	if c.reg.timer != nil {
		return
	}
	c.reg.timer = time.AfterFunc(grace, func() {
		c.reg.mu.Lock()
		c.reg.timer = nil
		n := len(c.reg.conns)
		c.reg.mu.Unlock()
		c.reap(grace, n)
	})
}

// reap закрывает соединения, которые не текущие и старше minAge; пишет channel.leak.
func (c *chn) reap(minAge time.Duration, n int) {
	cur := c.current()
	var stale []*conn
	c.reg.mu.Lock()
	for k := range c.reg.conns {
		if k.cl != cur && time.Since(k.born) >= minAge {
			stale = append(stale, k)
		}
	}
	c.reg.mu.Unlock()
	if n > 2 && len(stale) > 0 { // >2: оставить самое новое не-текущее (возможно, идёт переключение)
		newest := 0
		for i, k := range stale {
			if k.born.After(stale[newest].born) {
				newest = i
			}
		}
		if n-len(stale) < 2 {
			stale = append(stale[:newest], stale[newest+1:]...)
		}
	}
	if len(stale) == 0 {
		return
	}
	c.log.Warn("channel.leak", "kind", "session", "sessions", n, "closing", len(stale))
	for _, k := range stale {
		k.close()
	}
}

// SingboxEvent — событие из журнала канального sing-box (вызывается читателем stdout, не блокирует).
func (c *chn) SingboxEvent(kind string) {
	switch kind {
	case "network-changed": // sing-box сам заметил смену сети: проверка через общий механизм (тишина, 2 пробы)
		c.Underlay()
	case "outbound-error": // ошибка соединения через путь: одиночная проверка живой сессии
		select {
		case c.sbEvent <- struct{}{}:
		default:
		}
	}
}

// sbWatcher: по событию журнала — немедленная одиночная проверка сессии (не чаще sbCheckGap); мертва — handover.
func (c *chn) sbWatcher(ctxDone <-chan struct{}, check func() bool) {
	var last time.Time
	for {
		select {
		case <-ctxDone:
			return
		case <-c.sbEvent:
		}
		if !c.isUp() || time.Since(last) < sbCheckGap {
			continue
		}
		alive := check()
		last = time.Now()
		c.log.Info("sb-event-check", "alive", alive)
		if !alive {
			select {
			case c.handover <- struct{}{}:
			default:
			}
		}
	}
}
