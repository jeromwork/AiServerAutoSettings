package core

import (
	"context"
	"sort"
	"strings"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/platform"
)

const netDebounce = 700 * time.Millisecond

// debounce сливает пачку событий (сеть при смене шлёт их десятки) в одно после тишины d. Таймер одноразовый, без опроса.
func debounce(ctx context.Context, in <-chan struct{}, d time.Duration) <-chan struct{} {
	out := make(chan struct{}, 1)
	go func() {
		defer close(out)
		var t *time.Timer
		var fire <-chan time.Time
		for {
			select {
			case <-ctx.Done():
				if t != nil {
					t.Stop()
				}
				return
			case _, ok := <-in:
				if !ok {
					return
				}
				if t == nil {
					t = time.NewTimer(d)
				} else {
					if !t.Stop() {
						select {
						case <-t.C:
						default:
						}
					}
					t.Reset(d)
				}
				fire = t.C
			case <-fire:
				fire = nil
				select {
				case out <- struct{}{}:
				default:
				}
			}
		}
	}()
	return out
}

// netSignature — отпечаток физической сети: имя внешнего интерфейса и его адреса. Чужие TUN/Tailscale/Hyper-V
// (их маршруты и адреса меняются постоянно) в него не входят — на них канал не перестраивается.
func netSignature(ifs []api.Iface) string {
	name := platform.PickPhysical(ifs)
	if name == "" {
		return ""
	}
	var addrs []string
	for _, f := range ifs {
		if f.Name == name {
			addrs = append(addrs, f.Addrs...)
		}
	}
	sort.Strings(addrs)
	return name + "|" + strings.Join(addrs, ",")
}

// netReact — реакция на смену сети; зависимости вынесены для проверки.
type netReact struct {
	sig     func() string         // отпечаток физической сети
	sbReset func(context.Context) // sing-box: пересчитать интерфейс выхода / сбросить соединения
	chReset func()                // канал: оборвать попытку, круг путей с первого
	chUp    func() bool           // канал сейчас up
	log     api.Logger
	last    string
	inited  bool
}

// onChange вызывается после debounce. Перестраивает, если физическая сеть реально изменилась
// или канал сейчас не up (тогда смена могла быть причиной и лишний повтор безвреден).
func (n *netReact) onChange(ctx context.Context) bool {
	cur := n.sig()
	changed := n.inited && cur != n.last
	n.last, n.inited = cur, true
	if !changed && n.chUp() {
		return false
	}
	n.log.Info("net-changed", "physical", cur, "changed", changed)
	if n.sbReset != nil {
		n.sbReset(ctx)
	}
	if n.chReset != nil {
		n.chReset()
	}
	return true
}

func (c *core) watchNet(ctx context.Context) {
	n := &netReact{
		log: c.log,
		sig: func() string {
			ifs, err := c.plat.Interfaces()
			if err != nil {
				return ""
			}
			return netSignature(ifs)
		},
		sbReset: func(ctx context.Context) {
			if sb, ok := c.getSb().(interface {
				NetChanged(context.Context) (bool, error)
			}); ok {
				if _, err := sb.NetChanged(ctx); err != nil {
					c.log.Warn("core: net-singbox", "err", err.Error())
				}
			}
		},
		chReset: func() {
			if ch, ok := c.getCh().(interface{ NetChanged() }); ok {
				ch.NetChanged()
			}
		},
		chUp: func() bool { ch := c.getCh(); return ch != nil && ch.State().State == "up" },
	}
	n.last, n.inited = n.sig(), true
	for range debounce(ctx, platform.WatchNet(ctx), netDebounce) {
		if n.onChange(ctx) && c.tun != nil {
			c.tun.reconcile(ctx, "net-changed")
		}
	}
}
