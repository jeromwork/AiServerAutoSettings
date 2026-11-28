package channel

import (
	"context"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Замер путей селектора chan: реальный HTTP-запрос через каждый путь (Clash API /proxies/<имя>/delay), а не голый
// TCP-connect: чужой TUN (Happ) может сам принять TCP. Запускается только по событиям (старт канала, смена сети,
// смена чужого VPN, обрыв сессии), периодических опросов нет.
const (
	measureTimeout = 3 * time.Second
	// Цели замера. Первая — mixed-in сервера (127.0.0.1:1080 у выхода пути): любой HTTP-ответ (400) приходит с самого
	// сервера, без выхода в интернет и без 104. Серверный sing-box при этом пропускает и интернет (route.final), поэтому
	// запасная цель — gstatic, если на сервере mixed-in нет.
	measureURL  = "http://127.0.0.1:1080/"
	measureURL2 = "http://www.gstatic.com/generate_204"
	// Гистерезис: с живого пути уходим, только если новый быстрее и на долю, и на абсолют.
	hystRatio = 0.7
	hystMinMs = 30
)

// measurePaths — задержка в мс по каждому пути; путь без ответа в карте отсутствует.
func (c *chn) measurePaths(names []string) map[string]int {
	if c.measureFn != nil {
		return c.measureFn(names)
	}
	out := c.measureVia(names, measureURL)
	if len(out) == 0 { // на сервере нет локальной цели — пробуем интернет-цель
		out = c.measureVia(names, measureURL2)
	}
	return out
}

func (c *chn) measureVia(names []string, target string) map[string]int {
	var mu sync.Mutex
	out := map[string]int{}
	var wg sync.WaitGroup
	for _, n := range names {
		wg.Add(1)
		go func(n string) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), measureTimeout+time.Second)
			defer cancel()
			var r struct {
				Delay int `json:"delay"`
			}
			q := url.Values{"url": {target}, "timeout": {"3000"}}
			if err := c.sb.Clash(ctx, "GET", "/proxies/"+url.PathEscape(n)+"/delay?"+q.Encode(), nil, &r); err != nil || r.Delay <= 0 {
				return
			}
			mu.Lock()
			out[n] = r.Delay
			mu.Unlock()
		}(n)
	}
	wg.Wait()
	return out
}

// pickByMeasure — чистый выбор: самый быстрый рабочий не-плохой путь; живой cur сохраняется, пока выигрыш
// меньше гистерезиса. ok=false — рабочих замеров нет, нужен порядок по рангу.
func pickByMeasure(names []string, ms map[string]int, bad func(string) bool, cur string) (string, bool) {
	best := ""
	for _, n := range names { // порядок по рангу решает ничьи
		if ms[n] <= 0 || bad(n) {
			continue
		}
		if best == "" || ms[n] < ms[best] {
			best = n
		}
	}
	if best == "" {
		return "", false
	}
	if cur != "" && cur != best && ms[cur] > 0 && !bad(cur) {
		if float64(ms[best]) > float64(ms[cur])*hystRatio || ms[cur]-ms[best] < hystMinMs {
			return cur, true
		}
	}
	return best, true
}

func (c *chn) isBad(n string, now time.Time) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return now.Before(c.badUntil[n])
}

// choosePath замеряет пути и выбирает; cur — путь живой сессии ("" — сессии нет). Пишет в журнал.
func (c *chn) choosePath(names []string, cur string) string {
	now := time.Now()
	ms := c.measurePaths(names)
	var parts []string
	for _, n := range names {
		if v, ok := ms[n]; ok && v > 0 {
			parts = append(parts, n+"="+strconv.Itoa(v))
		} else {
			parts = append(parts, n+"=fail")
		}
	}
	pick, ok := pickByMeasure(names, ms, func(n string) bool { return c.isBad(n, now) }, cur)
	why := ""
	if !ok {
		pick, why = c.firstGood(names, now), " (замер не удался, порядок по рангу)"
	}
	c.log.Info("path-measure", "msg", "замер путей: "+strings.Join(parts, " ")+", выбран "+pick+why)
	return pick
}

// selectBest — замер и выбор пути селектора (если не закреплён другой); cur — путь живой сессии для гистерезиса.
func (c *chn) selectBest(cur string) string {
	if c.sb == nil || c.o.Mode.NoSingbox {
		return ""
	}
	c.mu.Lock()
	pinned := time.Now().Before(c.pinned)
	c.mu.Unlock()
	names := c.sb.PathNames()
	if pinned || len(names) == 0 {
		return ""
	}
	pick := c.choosePath(names, cur)
	_ = c.selectPath(pick)
	return pick
}

// remeasureLive — событие под живой сессией (смена сети/чужого VPN): замер в фоне; если есть заметно лучший путь —
// запрос handover (новая сессия поднимается до закрытия старой). Не опрос: вызывается только из события.
func (c *chn) remeasureLive() {
	if c.sb == nil || c.o.Mode.NoSingbox {
		return
	}
	go func() {
		c.mu.Lock()
		pinned := time.Now().Before(c.pinned)
		cur, up := c.st.Path, c.st.State == "up"
		c.mu.Unlock()
		names := c.sb.PathNames()
		if pinned || !up || len(names) < 2 {
			return
		}
		pick := c.choosePath(names, cur)
		if pick == "" || pick == cur {
			return
		}
		c.mu.Lock()
		c.pendingPick = pick
		c.mu.Unlock()
		select {
		case c.handover <- struct{}{}:
		default:
		}
	}()
}
