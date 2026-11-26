package webui

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"
)

// hub — событийный канал страницы (SSE): без опросов. Последнее значение каждого вида хранится и
// отдаётся сразу при подключении, остальное — по мере появления. Медленный подписчик теряет старое.
type hub struct {
	mu   sync.Mutex
	last map[string]string // вид → JSON последнего события
	subs map[int]chan evt
	seq  int
}

type evt struct{ kind, data string }

func newHub() *hub { return &hub{last: map[string]string{}, subs: map[int]chan evt{}} }

func (h *hub) publish(kind string, data any) {
	b, err := json.Marshal(data)
	if err != nil {
		return
	}
	e := evt{kind, string(b)}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.last[kind] = e.data
	for _, ch := range h.subs {
		for {
			select {
			case ch <- e:
			default:
				select {
				case <-ch:
					continue
				default:
				}
			}
			break
		}
	}
}

func (h *hub) subscribe(replay bool) (<-chan evt, func()) {
	h.mu.Lock()
	defer h.mu.Unlock()
	ch := make(chan evt, 64)
	if replay {
		for k, v := range h.last {
			ch <- evt{k, v}
		}
	}
	id := h.seq
	h.seq++
	h.subs[id] = ch
	return ch, func() {
		h.mu.Lock()
		delete(h.subs, id)
		h.mu.Unlock()
	}
}

// Publish — событие для страницы (вид: status, apply, paths, singbox, channel ...). Данные должны быть
// уже очищены от секретов и адресов.
func (u *UI) Publish(kind string, data any) { u.hub.publish(kind, data) }

func (u *UI) handleEvents(w http.ResponseWriter, req *http.Request) {
	if !u.checkAuth(w, req) {
		return
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "stream unsupported", http.StatusInternalServerError)
		return
	}
	// Поток живёт долго: общий WriteTimeout сервера на него не распространяется.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Time{})
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Referrer-Policy", "no-referrer")
	w.WriteHeader(http.StatusOK)
	ch, unsub := u.hub.subscribe(u.snap == nil)
	defer unsub()
	fmt.Fprint(w, "retry: 1000\n\n")
	if u.snap != nil {
		// Сначала подписка, потом снимок: событие между ними придёт повторно, но не потеряется.
		for kind, v := range u.snap() {
			if b, err := json.Marshal(v); err == nil {
				fmt.Fprintf(w, "event: %s\ndata: %s\n\n", kind, b)
			}
		}
	}
	fl.Flush()
	for {
		select {
		case <-req.Context().Done():
			return
		case <-u.done:
			return
		case e := <-ch:
			fmt.Fprintf(w, "event: %s\ndata: %s\n\n", e.kind, e.data)
			fl.Flush()
		}
	}
}

// callTimeout выполняет f не дольше d: страница получает понятную ошибку вместо вечного ожидания.
func callTimeout(d time.Duration, what string, f func() error) error {
	res := make(chan error, 1)
	go func() { res <- f() }()
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case err := <-res:
		return err
	case <-t.C:
		return fmt.Errorf("%s: не завершилось за %d с, попробуйте ещё раз или посмотрите журнал", what, int(d.Seconds()))
	}
}

// SetSnapshot задаёт источник ТЕКУЩЕГО состояния (вид → значение): при подключении страница получает его,
// а не последнее опубликованное событие (которое могло устареть). Вызывать до Start.
func (u *UI) SetSnapshot(f func() map[string]any) { u.snap = f }
