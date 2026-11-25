// Package vpnrun: VPN-sing-box (TUN) — единственный процесс, которому нужны права.
// Права выдаются один раз в Install (с паролем администратора), дальше Start/Stop/Running — без запросов.
package vpnrun

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/bus"
)

const label = "ru.remoteagents.vpn" // служба (Mac) / задача (Windows)

// Runner: Install/Uninstall/start/stop/Running — в файлах по ОС; Start/Stop/Reset — общие (со сторожем).
type Runner struct {
	Procs    api.Procs // нужен только на Linux (запуск обычным ребёнком)
	Log      api.Logger
	Bus      *bus.Bus // vpn.exited / vpn.gave_up (may be nil)
	Sing     string   // путь к sing-box: <home>/runtime/<имя exe> (как в v2)
	Conf     string   // путь к конфигу: <home>/private/vpn.json (как в v2)
	API      string   // clash_api.external_controller из конфига VPN, напр. 127.0.0.1:9090
	Secret   string   // clash_api.secret
	ProbeURL string   // адрес контрольной проверки (ровно 65536 байт); пусто = DefaultProbeURL
	LANOnly  bool     // процесс содержит только TUN ЛВС: контроль общего VPN не нужен
	Exits    []string // все узлы выхода VPN-мостов; nil — совместимый Exit
	Exit     string   // тег outbound узла выхода в конфиге VPN (по нему ищем ошибки соединений); пусто = "proxy"

	applyMu    sync.Mutex
	dnsMu      sync.Mutex
	dnsAddress string
	dnsDomains []string
	dnsApplied bool
	reconcile  func(context.Context, bus.Event) error
	changes    chan bus.Event
	mu         sync.Mutex
	proc       api.Process
	gen        int
	cancel     context.CancelFunc
	ctx        context.Context
	rootCancel context.CancelFunc
	gaveUp     bool // падения подряд исчерпали попытки; ждём ручной Start/настройки
	dead       bool // остановлены из-за мёртвого туннеля: ждём net.changed
	deadN      int  // мёртвых туннелей подряд (сбрасывается ручным Start)
	unsub      []func()
}

// New: пути постоянные, как в v2 (vpn.py), ничего не запоминается в файле.
func New(home string, procs api.Procs, log api.Logger, b *bus.Bus, apiAddr, secret string) *Runner {
	exe := "ra2-vpn"
	if runtime.GOOS == "windows" {
		exe = "RA2-VPN.exe"
	}
	ctx, cancel := context.WithCancel(context.Background())
	r := &Runner{Procs: procs, Log: log, Bus: b, API: apiAddr, Secret: secret, ctx: ctx, rootCancel: cancel,
		Sing: filepath.Join(home, "runtime", exe), Conf: filepath.Join(home, "private", "vpn.json")}
	r.changes = make(chan bus.Event, 32)
	if b != nil {
		for _, topic := range []string{"net.changed", "channel.up", "channel.down", "settings.loaded", "app.stop"} {
			r.unsub = append(r.unsub, b.Subscribe(topic, func(ev bus.Event) {
				select {
				case r.changes <- ev:
				case <-ctx.Done():
				}
			}))
		}
	}
	go r.changeLoop()

	return r
}

// Configure сериализует применение настроек и событий сети.
func (r *Runner) Configure(fn func() error) error {
	r.applyMu.Lock()
	defer r.applyMu.Unlock()
	return fn()
}
func (r *Runner) OnChange(fn func(context.Context, bus.Event) error) {
	r.mu.Lock()
	r.reconcile = fn
	r.mu.Unlock()
}
func (r *Runner) changeLoop() {
	for {
		select {
		case <-r.ctx.Done():
			return
		case ev := <-r.changes:
			if ev.Topic == "app.stop" {
				if err := r.Stop(); err != nil && r.Log != nil {
					r.Log.Error("vpn.stop", "err", err.Error())
				}
				r.Close()
				return
			}
			r.mu.Lock()
			fn := r.reconcile
			r.mu.Unlock()
			if fn != nil {
				if err := fn(r.ctx, ev); err != nil && r.Log != nil {
					r.Log.Error("vpn.apply", "err", err.Error())
				}
			} else if ev.Topic == "net.changed" {
				r.retryAfterDead()
			}
		}
	}
}

// retryAfterDead: net.changed. Повтор только если мы сами остановили VPN как мёртвый и попыток ещё меньше maxFails.
func (r *Runner) retryAfterDead() {
	r.mu.Lock()
	ok := r.dead && r.deadN < maxFails
	r.mu.Unlock()
	if !ok {
		return
	}
	r.Log.Info("vpn.retry", "why", "net.changed")
	if err := r.begin(); err != nil {
		r.Log.Error("vpn.retry", "err", err.Error())
	}
}

// AllowEvent сохраняет предел трёх мёртвых туннелей; новый шанс даёт только net.changed.
func (r *Runner) AllowEvent(topic string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if topic == "settings.loaded" {
		r.dead = false
		r.deadN = 0
		r.gaveUp = false
	}
	return !r.gaveUp && (!r.dead || topic == "net.changed" && r.deadN < maxFails)
}
func (r *Runner) Resume() error { return r.begin() }

// Reset — при старте программы: VPN от прошлого запуска (задача Windows / служба Mac) мог пережить падение — останавливаем.
// На Linux он ребёнок в корзине и умирает с программой, там Running() всегда false. Адаптер после Reset снимает уборка (P10).
func (r *Runner) Reset() {
	if !r.Running() {
		return
	}
	r.Log.Warn("остался VPN от прошлого запуска: останавливаю")
	if err := r.Stop(); err != nil {
		r.Log.Error("vpn.reset", "err", err.Error())
	}
}

func run(name string, args ...string) ([]byte, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		err = fmt.Errorf("%s: %w: %s", name, err, strings.TrimSpace(string(out)))
	}
	return out, err
}

func runContext(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.WaitDelay = time.Second // bound output draining if the stop helper leaves descendants
	out, err := cmd.CombinedOutput()
	if err != nil {
		err = fmt.Errorf("%s: %w: %s", name, err, strings.TrimSpace(string(out)))
	}
	return out, err
}

func badPath(ps ...string) error {
	for _, p := range ps {
		if p == "" || strings.ContainsAny(p, "\"'<>&\r\n$`") {
			return fmt.Errorf("vpnrun: unsupported path %q", p)
		}
	}
	return nil
}

// Конфиг VPN (<home>/private/vpn.json) ОБЯЗАН содержать
//
//	"experimental": {"clash_api": {"external_controller": "<API>", "secret": "<Secret>"}}
//
// с теми же адресом (127.0.0.1:<порт>) и секретом, что переданы в New. Это делает генератор конфига.
// Через этот API мы держим одно постоянное соединение (GET /logs): оборвалось — sing-box умер;
// строки журнала по узлу выхода говорят, жив ли туннель (dead.go).

const (
	startWait = 10 * time.Second // сколько ждём, пока sing-box поднимет API после запуска
	maxFails  = 3                // падений подряд, после которых сдаёмся
)

// Start — ручной запуск: обнуляет счётчик падений, запускает sing-box и следит за ним событием
// (обрыв соединения с API). Упал сам — сразу перезапуск; maxFails подряд — стоп и ошибка в лог.
func (r *Runner) Start() error {
	r.mu.Lock()
	r.deadN = 0
	r.gaveUp = false
	r.mu.Unlock()
	return r.begin()
}

func (r *Runner) begin() error {
	r.mu.Lock()
	r.dead = false
	r.gen++
	gen := r.gen
	if r.cancel != nil {
		r.cancel()
	}
	ctx, cancel := context.WithCancel(r.ctx)
	r.cancel = cancel
	r.mu.Unlock()
	if err := r.start(); err != nil {
		cancel()
		return err
	}
	go r.monitor(ctx, gen)
	return nil
}

// Stop — намеренная остановка: сторож отпускается и перезапуска не будет.
func (r *Runner) Stop() error {
	r.mu.Lock()
	r.dead = false
	r.gen++
	if r.cancel != nil {
		r.cancel()
		r.cancel = nil
	}
	r.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return errors.Join(r.removeDNS(ctx), r.stop(ctx))
}

// Close — выключает сторожа (sing-box не трогает).
func (r *Runner) Close() {
	for _, u := range r.unsub {
		u()
	}
	r.rootCancel()
}

func (r *Runner) current(gen int) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.gen == gen && r.ctx.Err() == nil
}

// connect открывает поток /logs. Повторы — только в рамках одного ожидания старта (startWait):
// API появляется не сразу после запуска. exited (если есть) прерывает ожидание, когда процесс уже умер.
func (r *Runner) connect(ctx context.Context) (io.ReadCloser, error) {
	exited := r.exited()
	ctx2, stop := context.WithTimeout(ctx, startWait)
	defer stop()
	cl := &http.Client{Transport: &http.Transport{
		Proxy:                 nil,
		DialContext:           (&net.Dialer{Timeout: 2 * time.Second}).DialContext,
		ResponseHeaderTimeout: 3 * time.Second,
	}}
	var last error
	for {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+r.API+"/logs?level="+logLevel, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Authorization", "Bearer "+r.Secret)
		resp, err := cl.Do(req)
		if err == nil && resp.StatusCode == http.StatusOK {
			return resp.Body, nil
		}
		if err == nil {
			resp.Body.Close()
			err = fmt.Errorf("api status %d", resp.StatusCode)
		}
		last = err
		select {
		case <-ctx2.Done():
			return nil, fmt.Errorf("vpnrun: api not available: %w", last)
		case <-exited:
			return nil, fmt.Errorf("vpnrun: process exited: %w", last)
		case <-time.After(200 * time.Millisecond): // пауза между попытками внутри одного ожидания старта
		}
	}
}

// monitor — один цикл на запуск: соединились → ждём обрыва → перезапуск, пока не набралось maxFails.
func (r *Runner) monitor(ctx context.Context, gen int) {
	fails := 0
	for {
		body, err := r.connect(ctx)
		if err == nil {
			r.Log.Info("vpn.up")
			r.enableDNS(ctx, gen)
			tags, lanOnly := r.exitTags()
			w := newTunnelWatch(tags)
			sc := bufio.NewScanner(body) // блокируется до обрыва: это и есть событие «умер»
			sc.Buffer(make([]byte, 64*1024), 1<<20)
			for sc.Scan() {
				var m struct {
					Payload string `json:"payload"`
				}
				if json.Unmarshal(sc.Bytes(), &m) != nil || lanOnly || !w.feed(m.Payload) {
					continue
				}
				// Ошибка соединения — повод для ОДНОЙ проверки; чтение журнала не блокируем.
				go r.checkTunnel(ctx, gen, w, append([]string(nil), w.last...))
			}
			body.Close()
			err = fmt.Errorf("connection lost")
		}
		if ctx.Err() != nil || !r.current(gen) {
			return // остановлен нами
		}
		cleanCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		if e := r.removeDNS(cleanCtx); e != nil && r.Log != nil {
			r.Log.Error("lan.dns.clear", "err", e.Error())
		}
		cancel()
		fails++
		r.Bus.Publish("vpn.exited", map[string]any{"err": err.Error(), "fails": fails})
		if fails >= maxFails {
			r.giveUp(gen, fails)
			return
		}
		if err := r.Configure(func() error {
			if !r.current(gen) {
				return nil
			}
			return r.start()
		}); err != nil {
			fails++
			r.Log.Error("vpn.start", "err", err.Error(), "fails", fails)
			if fails >= maxFails {
				r.giveUp(gen, fails)
				return
			}
		}
	}
}

// Exhaustion must fail open: stop the VPN within one bounded action before
// dropping supervision. A stop failure is reported, never presented as success.
func (r *Runner) giveUp(gen, fails int) {
	_ = r.Configure(func() error {
		if !r.current(gen) {
			return nil
		}
		data := map[string]any{"fails": fails, "hint": "VPN упал 3 раза подряд; нужен ручной Start"}
		if err := r.Stop(); err != nil {
			r.Log.Error("vpn.gave_up.stop", "err", err.Error())
			data["stop_error"] = err.Error()
		}
		r.mu.Lock()
		r.gaveUp = true
		r.mu.Unlock()
		r.Bus.Publish("vpn.gave_up", data)
		return nil
	})
}

func (r *Runner) SetExits(tags []string, lanOnly bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.Exit = ""
	r.Exits = append([]string(nil), tags...)
	r.LANOnly = lanOnly
}
func (r *Runner) exitTags() ([]string, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.Exits) != 0 {
		return append([]string(nil), r.Exits...), r.LANOnly
	}
	if r.Exit != "" {
		return []string{r.Exit}, r.LANOnly
	}
	return []string{"proxy"}, r.LANOnly
}

// checkTunnel: контрольная проверка по событию; провал = туннель мёртв.
func (r *Runner) checkTunnel(ctx context.Context, gen int, w *tunnelWatch, errs []string) {
	url := r.ProbeURL
	if url == "" {
		url = DefaultProbeURL
	}
	err := probe(ctx, url)
	if err == nil {
		w.probing.Store(false) // жив: ничего не делаем
		return
	}
	if ctx.Err() != nil || !r.current(gen) {
		return // остановлены нами, проверка недействительна
	}
	r.tunnelDead(gen, "probe failed: "+err.Error(), errs)
}

// tunnelDead: sing-box жив, узел выхода молчит. Останавливаем VPN (интернет идёт напрямую, fail-open),
// сообщаем в шину; дальше — только net.changed (retryAfterDead) или ручной Start.
func (r *Runner) tunnelDead(gen int, reason string, errs []string) {
	_ = r.Configure(func() error {
		r.mu.Lock()
		if r.gen != gen || r.ctx.Err() != nil {
			r.mu.Unlock()
			return nil
		}
		r.deadN++
		n := r.deadN
		r.mu.Unlock()
		r.Log.Warn("vpn.dead", "reason", reason, "n", n)
		if err := r.Stop(); err != nil {
			r.Log.Error("vpn.dead.stop", "err", err.Error())
		}
		r.mu.Lock()
		r.dead = true // после Stop (он сбрасывает флаг)
		r.mu.Unlock()
		r.Bus.Publish("vpn.dead", map[string]any{"reason": reason, "errors": errs, "n": n, "gave_up": n >= maxFails})
		return nil
	})
}
