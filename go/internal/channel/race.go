package channel

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

// Гонка путей (happy eyeballs). У sing-box на каждый путь свой локальный вход (PathAddr): канал открывает SSH по
// нескольким путям почти одновременно — следующий кандидат стартует через raceStagger после предыдущего или сразу, когда
// предыдущий отказал, — и берёт первое успешное SSH-рукопожатие; остальные отменяются. Только рукопожатие: серверную
// сессию (claim «последняя побеждает») поднимает победитель, проигравшие её не трогают.
var (
	raceStagger     = 250 * time.Millisecond
	raceMaxInflight = 8
	refusedBackoff  = 100 * time.Millisecond // отказ TCP на входе sing-box (рестарт, порт ещё не слушает): повтор по событию Ready или с шагом
	refusedRetries  = 4
	badAfterFailTTL = 2 * time.Minute
)

// pathRacer — sing-box, у которого есть вход на каждый путь.
type pathRacer interface {
	PathAddr(name string) string
}

func (c *chn) racer() pathRacer {
	if c.sb == nil || c.o.Mode.NoSingbox {
		return nil
	}
	r, _ := c.sb.(pathRacer)
	return r
}

// isDirectPath — путь без локального прокси чужого клиента: при чужом VPN он идёт через его TUN по маршрутам ОС.
func isDirectPath(n string) bool {
	if strings.Contains(n, "socks") || strings.HasSuffix(n, "-vpn") {
		return false
	}
	return n == "ssh-direct" || n == "vless-direct" || strings.HasPrefix(n, "ws-")
}

// raceOrder — порядок кандидатов: предпочтительный (prefer), затем хорошие перед плохими; при чужом VPN прямые пути впереди;
// внутри группы пути с известным замером по возрастанию задержки, остальные по рангу. Чистая функция.
func raceOrder(names []string, ms map[string]int, bad func(string) bool, foreign bool, prefer string) []string {
	type item struct {
		n    string
		rank int
		key  [3]int // плохой, не-прямой при чужом VPN, нет замера
	}
	items := make([]item, len(names))
	for i, n := range names {
		it := item{n: n, rank: i}
		if bad(n) {
			it.key[0] = 1
		}
		if foreign && !isDirectPath(n) {
			it.key[1] = 1
		}
		if ms[n] <= 0 {
			it.key[2] = 1
		}
		items[i] = it
	}
	sort.SliceStable(items, func(a, b int) bool {
		x, y := items[a], items[b]
		if (x.n == prefer) != (y.n == prefer) {
			return x.n == prefer
		}
		if x.key != y.key {
			for i := range x.key {
				if x.key[i] != y.key[i] {
					return x.key[i] < y.key[i]
				}
			}
		}
		if x.key[2] == 0 && ms[x.n] != ms[y.n] {
			return ms[x.n] < ms[y.n]
		}
		return x.rank < y.rank
	})
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.n
	}
	return out
}

func (c *chn) msSnapshot() map[string]int {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string]int, len(c.lastMs))
	for k, v := range c.lastMs {
		out[k] = v
	}
	return out
}

func (c *chn) markBad(n string, ttl time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.badUntil == nil {
		c.badUntil, c.losses = map[string]time.Time{}, map[string][]time.Time{}
	}
	if until := time.Now().Add(ttl); until.After(c.badUntil[n]) {
		c.badUntil[n] = until
	}
}

// acquire поднимает соединение до RALAB-CHANNEL-UP. Через sing-box — гонкой путей, иначе одним адресом.
// prefer — путь, который стартует первым (результат замера под живой сессией). Возвращает путь (для сообщений и состояния).
func (c *chn) acquire(ctx context.Context, first, handover bool, prefer string) (*conn, string, error) {
	path, addr := c.pickPath(ctx, first)
	if path == "" {
		return nil, "", ctx.Err()
	}
	if path == "chan" {
		if r := c.racer(); r != nil {
			if names := c.raceNames(); len(names) > 0 {
				return c.raceConnect(ctx, r, names, first, handover, prefer)
			}
		}
		if !handover && c.takeWantMeasure(first) {
			c.selectBest("")
		}
	}
	path = c.pathLabel(path)
	if handover {
		c.log.Info("handover-dial", "via", path, "addr", addr)
	} else {
		c.set("connecting", path, "", false)
		c.log.Info("dial", "via", path, "addr", addr)
	}
	k, err := c.connect(ctx, path, addr)
	return k, path, err
}

// raceNames — кандидаты гонки: закреплённый путь (ForcePath) или все пути селектора.
func (c *chn) raceNames() []string {
	names := c.sb.PathNames()
	c.mu.Lock()
	pinned, pn := time.Now().Before(c.pinned), c.pinName
	c.mu.Unlock()
	if pinned {
		for _, n := range names {
			if n == pn {
				return []string{pn}
			}
		}
	}
	return names
}

func (c *chn) raceConnect(ctx context.Context, r pathRacer, names []string, first, handover bool, prefer string) (*conn, string, error) {
	foreign := c.o.ForeignVPN != nil && c.o.ForeignVPN() != ""
	now := time.Now()
	order := raceOrder(names, c.msSnapshot(), func(n string) bool { return c.isBad(n, now) }, foreign, prefer)
	if !handover && c.takeWantMeasure(first) {
		go c.measureBG(names) // замер только подсказка порядка на следующий раз: подключение его не ждёт
	}
	c.log.Info("race-start", "msg", "гонка путей: старт "+strings.Join(order, ", ")+map[bool]string{true: " (чужой VPN: прямые первыми)", false: ""}[foreign])
	t0 := time.Now()
	cl, ac, win, err := c.race(ctx, r, order)
	if err != nil {
		c.log.Warn("race-fail", "msg", "гонка путей: ни один путь не поднял SSH за "+strconv.FormatInt(time.Since(t0).Milliseconds(), 10)+" мс", "err", err.Error())
		return nil, "", err
	}
	c.log.Info("race-win", "msg", "гонка путей: "+win+" выиграл за "+strconv.FormatInt(time.Since(t0).Milliseconds(), 10)+" мс", "via", win, "ms", time.Since(t0).Milliseconds())
	go func() { _ = c.selectPath(win) }() // селектор — для отображения «текущего пути» и прежних потребителей
	if !handover {
		c.set("connecting", win, "", false)
	}
	k, err := c.establish(ctx, win, cl, ac)
	if err != nil {
		c.markBad(win, badAfterFailTTL)
		return nil, win, err
	}
	return k, win, nil
}

type raceRes struct {
	n   string
	cl  *ssh.Client
	ac  *activityConn
	err error
	ms  int64
}

// race — гонка SSH-рукопожатий по кандидатам в порядке order; победитель возвращается открытым, остальные закрыты.
func (c *chn) race(ctx context.Context, r pathRacer, order []string) (*ssh.Client, *activityConn, string, error) {
	rctx, cancel := context.WithTimeout(ctx, c.o.DialTimeout)
	defer cancel()
	results := make(chan raceRes, len(order))
	started, inflight := 0, 0
	fails := map[string]string{}
	launch := func() {
		n := order[started]
		started++
		inflight++
		t := time.Now()
		go func() {
			cl, ac, err := c.dialPath(rctx, r, n)
			results <- raceRes{n: n, cl: cl, ac: ac, err: err, ms: time.Since(t).Milliseconds()}
		}()
	}
	// проигравшие, успевшие дойти до успеха, закрываются; остальным отмена ctx обрывает рукопожатие
	drain := func() {
		left := inflight
		go func() {
			for ; left > 0; left-- {
				if x := <-results; x.err == nil {
					_ = x.cl.Close()
				}
			}
		}()
	}
	launch()
	timer := time.NewTimer(raceStagger)
	defer timer.Stop()
	for {
		select {
		case x := <-results:
			inflight--
			if x.err == nil {
				cancel() // остальные кандидаты отменены (рукопожатие победителя уже завершено и ctx его не касается)
				drain()
				return x.cl, x.ac, x.n, nil
			}
			fails[x.n] = x.err.Error()
			c.log.Warn("race-path-fail", "msg", "гонка путей: "+x.n+" отказал за "+strconv.FormatInt(x.ms, 10)+" мс", "via", x.n, "err", x.err.Error())
			if started == len(order) && inflight == 0 {
				return nil, nil, "", raceError(order, fails)
			}
			if started < len(order) && inflight < raceMaxInflight { // предыдущий отказал — следующий стартует сразу
				launch()
				resetTimer(timer, raceStagger)
			}
		case <-timer.C:
			if started < len(order) && inflight < raceMaxInflight {
				launch()
			}
			if started < len(order) {
				timer.Reset(raceStagger)
			}
		case <-rctx.Done():
			cancel()
			drain()
			if err := ctx.Err(); err != nil {
				return nil, nil, "", err
			}
			return nil, nil, "", raceError(order[:started], fails, "таймаут")
		}
	}
}

func resetTimer(t *time.Timer, d time.Duration) {
	if !t.Stop() {
		select {
		case <-t.C:
		default:
		}
	}
	t.Reset(d)
}

// raceError — одна ошибка по итогам гонки; если все отказы — несовпадение отпечатка, это видно по тексту (isHostKeyMismatch).
func raceError(tried []string, fails map[string]string, extra ...string) error {
	all, firstMismatch := len(fails) > 0, ""
	var parts []string
	for _, n := range tried {
		f, ok := fails[n]
		if !ok {
			parts = append(parts, n+": не успел")
			all = false
			continue
		}
		if !strings.Contains(f, "host key mismatch") {
			all = false
		} else if firstMismatch == "" {
			firstMismatch = f
		}
		if len(f) > 120 {
			f = f[:120] + "…"
		}
		parts = append(parts, n+": "+f)
	}
	if all {
		return errors.New(firstMismatch)
	}
	msg := "гонка путей: ни один путь не прошёл (" + strings.Join(parts, "; ") + ")"
	if len(extra) > 0 {
		msg += " — " + extra[0]
	}
	if len(msg) > 400 {
		msg = msg[:400] + "…"
	}
	return errors.New(msg)
}

// dialPath — SSH-рукопожатие по входу пути. Отказ TCP на входе sing-box (перезапуск, порт ещё не слушает) — не отказ пути:
// ждём событие Ready (или короткий шаг, если Ready уже закрыт) и берём адрес заново — порты могли смениться.
func (c *chn) dialPath(ctx context.Context, r pathRacer, name string) (*ssh.Client, *activityConn, error) {
	var lastErr error
	for attempt := 0; ; attempt++ {
		addr := r.PathAddr(name)
		if addr == "" {
			return nil, nil, fmt.Errorf("у пути %s нет входа sing-box", name)
		}
		cl, ac, err := c.dial(ctx, addr)
		if err == nil {
			return cl, ac, nil
		}
		lastErr = err
		var te *tcpError
		if !errors.As(err, &te) || attempt >= refusedRetries || ctx.Err() != nil {
			return nil, nil, lastErr
		}
		select {
		case <-c.sb.Ready(): // уже готов: подождать шаг, пока вход встанет
			d := time.NewTimer(refusedBackoff << attempt)
			select {
			case <-d.C:
			case <-ctx.Done():
				d.Stop()
				return nil, nil, lastErr
			}
		default: // sing-box перезапускается: ждём событие Ready
			select {
			case <-c.sb.Ready():
			case <-ctx.Done():
				return nil, nil, lastErr
			}
		}
	}
}

// measureBG — замер путей в фоне: журнал и подсказка порядка гонки. Выбор пути не меняет.
func (c *chn) measureBG(names []string) {
	ms := c.measurePaths(names)
	var parts []string
	for _, n := range names {
		if v, ok := ms[n]; ok && v > 0 {
			parts = append(parts, n+"="+strconv.Itoa(v))
		} else {
			parts = append(parts, n+"=fail")
		}
	}
	c.mu.Lock()
	c.lastMs = ms
	c.mu.Unlock()
	c.log.Info("path-measure", "msg", "замер путей (фон): "+strings.Join(parts, " "))
}
