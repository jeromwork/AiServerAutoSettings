package channel

import (
	"context"
	"time"
)

const (
	underlayQuiet   = 2 * time.Second // тишина без новых событий сети перед проверкой
	underlayRetry   = 3 * time.Second // страховка: повтор проверки после неудачи (новое событие сбрасывает)
	underlayRetries = 10
	probesNeeded    = 2 // подряд успешных проверок пути
	livenessWait    = 3 * time.Second
)

// verifier: событие «сеть под каналом изменилась» -> тихое окно (повторное событие начинает окно заново) -> 2 подряд
// успешные проверки пути -> проверка живой сессии; мертва — запрос handover (сначала подключить новую, потом закрыть старую).
// Пока проверки не прошли, ничего не переключается. Таймеры одноразовые (окно тишины и страховочный повтор), не опрос.
func (c *chn) verifier(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.ulEvent:
		}
		c.verifyOnce(ctx)
	}
}

func (c *chn) verifyOnce(ctx context.Context) {
	wait := underlayQuiet
	for attempt := 0; attempt <= underlayRetries; {
		// тихое окно: любое новое событие начинает его заново
		t := time.NewTimer(wait)
	quiet:
		for {
			select {
			case <-ctx.Done():
				t.Stop()
				return
			case <-c.ulEvent:
				attempt = 0
				wait = underlayQuiet
				if !t.Stop() {
					select {
					case <-t.C:
					default:
					}
				}
				t.Reset(wait)
			case <-t.C:
				break quiet
			}
		}
		if !c.isUp() { // сессия уже не up: круг путей ведёт основной цикл
			c.log.Info("underlay-verify", "result", "skip", "why", "сессия не up")
			return
		}
		ok := true
		for i := 0; i < probesNeeded && ok; i++ {
			ok = c.probePath(ctx)
			if ctx.Err() != nil {
				return
			}
		}
		if !ok {
			attempt++
			wait = underlayRetry
			c.log.Info("underlay-verify", "result", "path-not-ready", "attempt", attempt)
			continue
		}
		if c.sessionAlive(ctx) {
			c.log.Info("underlay-verify", "result", "session-alive", "action", "none")
			return
		}
		c.log.Info("underlay-verify", "result", "session-dead", "action", "handover")
		select {
		case c.handover <- struct{}{}:
		default:
		}
		return
	}
	c.log.Warn("underlay-verify", "result", "gave-up")
}

func (c *chn) isUp() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.st.State == "up"
}

// probePath — короткое рукопожатие ssh к серверу по текущему пути (без сессии и каналов), хост-ключ проверяется.
func (c *chn) probePath(ctx context.Context) bool {
	path, addr := c.pickPathNow()
	if path == "" {
		return false
	}
	pctx, cancel := context.WithTimeout(ctx, c.o.DialTimeout)
	defer cancel()
	cl, _, err := c.dial(pctx, addr)
	if err != nil {
		c.log.Info("underlay-probe", "via", path, "ok", false, "err", err.Error())
		return false
	}
	_ = cl.Close()
	c.log.Info("underlay-probe", "via", path, "ok", true)
	return true
}

// pickPathNow — как pickPath, но без ожидания sing-box: нет Ready — путь не готов.
func (c *chn) pickPathNow() (string, string) {
	if c.o.Mode.NoSingbox || c.sb == nil {
		return c.pickPath(context.Background(), false)
	}
	select {
	case <-c.sb.Ready():
		return "chan", c.sb.ChanAddr()
	default:
		return "", ""
	}
}

// sessionAlive — одиночная проверка живой сессии (keepalive-запрос с ожиданием livenessWait).
func (c *chn) sessionAlive(ctx context.Context) bool {
	cl := c.current()
	if cl == nil {
		return false
	}
	res := make(chan error, 1)
	go func() { _, _, err := cl.SendRequest("keepalive@openssh.com", true, nil); res <- err }()
	select {
	case err := <-res:
		return err == nil
	case <-time.After(livenessWait):
		return false
	case <-ctx.Done():
		return true
	}
}
