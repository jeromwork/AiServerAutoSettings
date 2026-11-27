//go:build windows

package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"fyne.io/systray"

	"remoteagents/internal/api"
	"remoteagents/internal/core"
	"remoteagents/internal/supervise"
)

// tray — значок в области уведомлений сторожа. Состояние берёт из потока событий страницы (SSE /api/events):
// без опросов; обрыв потока = ядро перезапускается, новое соединение — по сообщению ядра «ui» (trayURL).
type tray struct {
	p      api.Paths
	cancel func() // выход, когда ядро недоступно

	mu      sync.Mutex
	pageURL string
	stream  context.CancelFunc
	paused  bool
	state   string
	path    string

	pause *systray.MenuItem
}

var theTray *tray

// startTray запускает значок в отдельной горутине; возвращает функцию снятия значка.
func startTray(ctx context.Context, home string, cancel func()) func() {
	t := &tray{p: api.NewPaths(home), cancel: cancel, state: ""}
	theTray = t
	done := make(chan struct{})
	go func() {
		defer close(done)
		systray.Run(t.onReady, func() {})
	}()
	return func() {
		systray.Quit()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
		}
	}
}

// trayURL — ядро сообщило адрес страницы: (пере)подключить поток событий.
func trayURL(u string) {
	if t := theTray; t != nil {
		t.setURL(u)
	}
}

func (t *tray) onReady() {
	systray.SetIcon(icon(colGray))
	systray.SetTitle("RemoteAgents")
	systray.SetTooltip("RemoteAgents: запускается")
	open := systray.AddMenuItem("Открыть страницу", "")
	t.pause = systray.AddMenuItem("Пауза", "")
	vpnOff := systray.AddMenuItem("Выключить VPN", "")
	systray.AddSeparator()
	quit := systray.AddMenuItem("Выход", "")
	systray.SetOnTapped(t.open)
	go func() {
		for {
			select {
			case <-open.ClickedCh:
				t.open()
			case <-t.pause.ClickedCh:
				t.togglePause()
			case <-vpnOff.ClickedCh:
				go t.vpnOff()
			case <-quit.ClickedCh:
				t.exit()
				return
			}
		}
	}()
}

// currentURL — адрес из state\webui.url (свежий), иначе последний из сообщения ядра.
func (t *tray) currentURL() string {
	if b, err := os.ReadFile(filepath.Join(t.p.State, core.UIURLFile)); err == nil {
		if s := strings.TrimSpace(string(b)); s != "" {
			return s
		}
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.pageURL
}

func (t *tray) open() {
	if u := t.currentURL(); u != "" {
		_ = openURL(u)
	}
}

// call — POST к API страницы с токеном из адреса.
func (t *tray) call(path string, form url.Values) error {
	raw := t.currentURL()
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return os.ErrNotExist
	}
	req, err := http.NewRequest(http.MethodPost, u.Scheme+"://"+u.Host+path, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("X-Token", u.Query().Get("t"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	cl := &http.Client{Timeout: 60 * time.Second}
	resp, err := cl.Do(req)
	if err != nil {
		return err
	}
	return resp.Body.Close()
}

func (t *tray) togglePause() {
	t.mu.Lock()
	on := !t.paused
	t.mu.Unlock()
	v := "0"
	if on {
		v = "1"
	}
	go func() { _ = t.call("/api/pause", url.Values{"on": {v}}) }() // итог придёт событием "pause"
}

// vpnOff — «Выключить VPN» всегда срабатывает: сначала быстрый запрос к ядру (3 с), нет ответа/ошибка (ядро зависло, страница недоступна) —
// сторож сам убивает ядро (оно уносит с собой sing-box), cleanup снимает адаптер и фильтры, новое ядро стартует с выключенным VPN.
func (t *tray) vpnOff() {
	if t.callQuick("/api/vpn/off", 3*time.Second) == nil {
		go func() { _ = t.call("/api/vpn", url.Values{"mode": {"off"}}) }() // и в конфиг, чтобы после перезапуска не включился
		return
	}
	_ = supervise.ForceVPNOff(t.p)
}

// callQuick — POST к API страницы с коротким тайм-аутом; ошибка и не-200 — неудача.
func (t *tray) callQuick(path string, d time.Duration) error {
	raw := t.currentURL()
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return os.ErrNotExist
	}
	req, err := http.NewRequest(http.MethodPost, u.Scheme+"://"+u.Host+path, strings.NewReader(""))
	if err != nil {
		return err
	}
	req.Header.Set("X-Token", u.Query().Get("t"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := (&http.Client{Timeout: d}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var r struct{ OK bool }
	if resp.StatusCode != http.StatusOK || json.NewDecoder(resp.Body).Decode(&r) != nil || !r.OK {
		return os.ErrInvalid
	}
	return nil
}

func (t *tray) exit() {
	if err := t.call("/api/exit", url.Values{}); err != nil {
		t.cancel() // ядра нет: останавливаем сторожа сами
	}
}

func (t *tray) setURL(u string) {
	t.mu.Lock()
	if t.stream != nil {
		t.stream()
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.stream, t.pageURL = cancel, u
	t.mu.Unlock()
	go t.follow(ctx, u)
}

// follow читает SSE страницы до обрыва.
func (t *tray) follow(ctx context.Context, raw string) {
	u, err := url.Parse(raw)
	if err != nil {
		return
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.Scheme+"://"+u.Host+"/api/events", nil)
	if err != nil {
		return
	}
	req.Header.Set("X-Token", u.Query().Get("t"))
	resp, err := (&http.Client{}).Do(req)
	if err != nil {
		t.update(func() { t.state = "" })
		return
	}
	defer resp.Body.Close()
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	var kind string
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "event: "):
			kind = line[7:]
		case strings.HasPrefix(line, "data: "):
			t.event(kind, []byte(line[6:]))
		}
	}
	if ctx.Err() == nil {
		t.update(func() { t.state = "" }) // ядро ушло; новый адрес придёт, когда сторож поднимет ядро
	}
}

func (t *tray) event(kind string, data []byte) {
	switch kind {
	case "channel":
		var m struct{ State, Path string }
		if json.Unmarshal(data, &m) == nil {
			t.update(func() { t.state, t.path = strings.ToLower(m.State), m.Path })
		}
	case "pause":
		var m struct {
			Action, Stage string
			Paused        bool
		}
		if json.Unmarshal(data, &m) == nil && (m.Stage == "done" || m.Stage == "error") {
			t.update(func() { t.paused = m.Paused })
		}
	}
}

func (t *tray) update(f func()) {
	t.mu.Lock()
	f()
	paused, state, path := t.paused, t.state, t.path
	t.mu.Unlock()
	if t.pause == nil {
		return
	}
	var tip string
	col := colGray
	switch {
	case paused:
		tip = "RemoteAgents: пауза"
		t.pause.SetTitle("Продолжить")
	default:
		t.pause.SetTitle("Пауза")
		switch state {
		case "up":
			tip, col = "RemoteAgents: канал подключён", colGreen
			if path != "" {
				tip += " (" + path + ")"
			}
		case "down", "error":
			tip, col = "RemoteAgents: нет связи", colRed
		case "":
			tip = "RemoteAgents: ожидание ядра"
		default:
			tip, col = "RemoteAgents: подключение канала", colYellow
		}
	}
	systray.SetTooltip(tip)
	systray.SetIcon(icon(col))
}

type rgb struct{ r, g, b uint8 }

var (
	colGray   = rgb{140, 140, 140}
	colGreen  = rgb{46, 160, 67}
	colRed    = rgb{220, 53, 69}
	colYellow = rgb{230, 170, 20}
)

// icon строит ICO 32x32 (32 бита BGRA, без PNG — LoadImage понимает всегда): цветной круг с тёмным ободком.
func icon(c rgb) []byte {
	const n = 32
	pix := make([]byte, n*n*4)
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			dx, dy := float64(x)+0.5-n/2, float64(y)+0.5-n/2
			d := dx*dx + dy*dy
			var r, g, b, a uint8
			switch {
			case d <= 12*12:
				r, g, b, a = c.r, c.g, c.b, 255
			case d <= 15*15:
				r, g, b, a = 40, 40, 40, 255
			}
			o := ((n-1-y)*n + x) * 4 // BMP хранится снизу вверх
			pix[o], pix[o+1], pix[o+2], pix[o+3] = b, g, r, a
		}
	}
	mask := make([]byte, n*4) // AND-маска: нули (альфа из пикселей)
	var out []byte
	le := binary.LittleEndian
	out = le.AppendUint16(out, 0) // reserved
	out = le.AppendUint16(out, 1) // ICO
	out = le.AppendUint16(out, 1) // images
	out = append(out, n, n, 0, 0)
	out = le.AppendUint16(out, 1)  // planes
	out = le.AppendUint16(out, 32) // bpp
	out = le.AppendUint32(out, uint32(40+len(pix)+len(mask)))
	out = le.AppendUint32(out, 22)
	out = le.AppendUint32(out, 40) // BITMAPINFOHEADER
	out = le.AppendUint32(out, n)
	out = le.AppendUint32(out, 2*n)
	out = le.AppendUint16(out, 1)
	out = le.AppendUint16(out, 32)
	out = append(out, make([]byte, 24)...)
	out = append(out, pix...)
	return append(out, mask...)
}
