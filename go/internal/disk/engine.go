// Package disk — Диск: Syncthing под программой. Движок запускает syncthing, выкладывает на 127.0.0.1 порт синхронизации
// (проброс через канал на серверный sync), регистрирует новый ПК на сервере (Join) и ведёт состояния.
// Всё по событиям: состояние канала, выход процесса, смена сети, конец Join; единственные таймеры — одноразовые паузы
// перезапуска (30 с, вдвое до 5 мин; 5 падений подряд → ошибка до смены сети) и повтора Join (60 с, после 3 неудач 300 с).
package disk

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"remoteagents/internal/api"
)

const (
	DefaultSyncPort = 22001
	failsMax        = 5
	backoffBase     = 30 * time.Second
	backoffMax      = 5 * time.Minute
	stableAfter     = 120 * time.Second
	joinRetry       = 60 * time.Second
	joinRetryLong   = 300 * time.Second
	joinFailsLong   = 3
	lockName        = "engine.lock"
)

// Deps — зависимости движка (собирает core).
type Deps struct {
	Cfg         Config
	Channel     api.Channel
	ChannelJSON json.RawMessage // расшифрованный paths.channel: вход sync → серверный порт; может быть пустым
	Procs       api.Procs
	Log         api.Logger
	Paths       api.Paths
	Bin         string   // исполняемый файл syncthing (или syncthingtray); пусто → Диск «не установлен»
	BinArgs     []string // аргументы перед "serve" (для syncthingtray: "syncthing")
	OnState     func(Snapshot)
}

type joinResult struct {
	info ServerInfo
	err  error
}

// Engine — api.Component.
type Engine struct {
	d   Deps
	log api.Logger

	mu   sync.Mutex
	snap Snapshot

	wake    chan struct{}
	netFlag atomic.Bool
	cancel  context.CancelFunc
	done    chan struct{}

	// Ниже — только горутина loop.
	up         bool
	fails      int
	nextAt     time.Time
	timer      *time.Timer
	proc       api.Process
	procOut    io.Closer
	procAt     time.Time
	unlock     func()
	fwd        *portForward
	joining    bool
	joinFails  int
	joinNextAt time.Time
	joinDone   chan joinResult
	joinCancel context.CancelFunc
	stopping   bool
}

func New(d Deps) *Engine {
	if d.Log == nil {
		panic("disk: Deps.Log обязателен")
	}
	return &Engine{d: d, log: d.Log.With("disk"), wake: make(chan struct{}, 1), joinDone: make(chan joinResult, 1),
		snap: Snapshot{State: StateAbsent, Text: StateAbsent.Text()}}
}

func (e *Engine) Name() string { return "disk" }

func (e *Engine) Status() map[string]any {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.snap.Map()
}

// Snapshot — текущее состояние.
func (e *Engine) Snapshot() Snapshot {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.snap
}

// NetChanged — сменилась физическая сеть: из состояния error движок выходит и пробует снова.
func (e *Engine) NetChanged() {
	e.netFlag.Store(true)
	e.poke()
}

func (e *Engine) poke() {
	select {
	case e.wake <- struct{}{}:
	default:
	}
}

func (e *Engine) home() string {
	if h := e.d.Cfg.Home; h != "" {
		return h
	}
	return filepath.Join(e.d.Paths.Home, "disk")
}

func (e *Engine) syncPort() int {
	if p := e.d.Cfg.SyncPort; p > 0 {
		return p
	}
	return DefaultSyncPort
}

func (e *Engine) Start(ctx context.Context) error {
	if e.d.Channel == nil {
		return errors.New("disk: нужен канал")
	}
	lctx, cancel := context.WithCancel(ctx)
	e.cancel = cancel
	e.done = make(chan struct{})
	updates, unsub := e.d.Channel.Subscribe()
	e.up = e.d.Channel.State().State == "up"
	go func() {
		defer close(e.done)
		defer unsub()
		e.loop(lctx, updates)
	}()
	return nil
}

func (e *Engine) Stop(ctx context.Context) error {
	if e.cancel == nil {
		return nil
	}
	e.cancel()
	select {
	case <-e.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (e *Engine) loop(ctx context.Context, updates <-chan api.ChannelState) {
	e.eval(ctx)
	for {
		var procDone <-chan struct{}
		if e.proc != nil {
			procDone = e.proc.Done()
		}
		var timerC <-chan time.Time
		if e.timer != nil {
			timerC = e.timer.C
		}
		select {
		case <-ctx.Done():
			e.shutdown()
			return
		case st, ok := <-updates:
			if !ok {
				updates = nil
				continue
			}
			up := st.State == "up"
			if up != e.up {
				e.up = up
				e.log.Info("disk: channel", "up", up)
			}
		case <-e.wake:
			if e.netFlag.Swap(false) && e.snap.State == StateError {
				e.fails, e.nextAt, e.joinFails, e.joinNextAt = 0, time.Time{}, 0, time.Time{}
				e.log.Info("disk: net-changed, повтор после ошибки")
			}
		case <-procDone:
			e.onExit()
		case <-timerC:
			e.timer = nil
		case r := <-e.joinDone:
			e.onJoined(r)
		}
		e.eval(ctx)
	}
}

func (e *Engine) arm(at time.Time) {
	if e.timer != nil {
		e.timer.Stop()
	}
	e.timer = time.NewTimer(max(time.Until(at), time.Millisecond))
}

func backoff(fails int) time.Duration {
	d := backoffBase
	for i := 1; i < fails && d < backoffMax; i++ {
		d *= 2
	}
	return min(d, backoffMax)
}

func (e *Engine) onExit() {
	p := e.proc
	e.proc = nil
	e.closeOut()
	if e.unlock != nil {
		e.unlock()
		e.unlock = nil
	}
	if e.stopping {
		return
	}
	if time.Since(e.procAt) > stableAfter {
		e.fails = 0
	}
	e.fails++
	e.nextAt = time.Now().Add(backoff(e.fails))
	e.log.Warn("disk: syncthing-exit", "code", p.ExitCode(), "fails", e.fails)
}

func (e *Engine) onJoined(r joinResult) {
	e.joining = false
	e.joinCancel = nil
	if r.err != nil {
		if errors.Is(r.err, context.Canceled) && e.stopping {
			return
		}
		e.joinFails++
		wait := joinRetry
		if e.joinFails >= joinFailsLong {
			wait = joinRetryLong
		}
		e.joinNextAt = time.Now().Add(wait)
		e.log.Warn("disk: join-failed", "fails", e.joinFails, "err", r.err.Error())
		return
	}
	e.joinFails, e.joinNextAt = 0, time.Time{}
	e.log.Info("disk: joined")
}

func (e *Engine) set(s State, why string) {
	e.mu.Lock()
	changed := e.snap.State != s || e.snap.Why != why
	e.snap = Snapshot{State: s, Why: why, Text: s.Text()}
	snap := e.snap
	e.mu.Unlock()
	if changed {
		e.log.Info("disk: state", "state", string(s), "why", why)
		if e.d.OnState != nil {
			e.d.OnState(snap)
		}
	}
}

func (e *Engine) eval(ctx context.Context) {
	if ctx.Err() != nil || e.stopping {
		return
	}
	if e.proc != nil {
		e.set(StateRunning, "")
		return
	}
	cfg := e.d.Cfg
	if cfg.Enabled != nil && !*cfg.Enabled {
		e.set(StateAbsent, "выключен в конфиге")
		return
	}
	if e.d.Bin == "" {
		e.set(StateAbsent, "нет syncthing")
		return
	}
	home := e.home()
	if needJoin(home) {
		e.evalJoin(ctx, home)
		return
	}
	if e.fails >= failsMax {
		e.set(StateError, "syncthing не держится: ждём смену сети")
		return
	}
	if !e.up {
		e.set(StateWait, "канал не поднят")
		return
	}
	if now := time.Now(); now.Before(e.nextAt) {
		e.arm(e.nextAt)
		e.set(StateWait, "пауза после падения")
		return
	}
	srv := serverSyncPort(e.d.ChannelJSON, home)
	if srv == 0 {
		e.set(StateError, "не известен серверный порт синхронизации")
		return
	}
	if e.fwd != nil && e.fwd.srv != srv {
		e.fwd.close()
		e.fwd = nil
	}
	if e.fwd == nil {
		f, err := openForward(e.d.Channel, e.syncPort(), srv)
		if err != nil {
			e.set(StateError, fmt.Sprintf("порт %d занят: Диск уже ведёт другая программа", e.syncPort()))
			return
		}
		e.fwd = f
	}
	unlock, err := lockFile(filepath.Join(home, lockName))
	if err != nil {
		e.nextAt = time.Now().Add(backoffBase)
		e.arm(e.nextAt)
		e.set(StateWait, "папку Диска держит другая программа")
		return
	}
	if err := e.startProc(ctx, home); err != nil {
		unlock()
		e.fails++
		e.nextAt = time.Now().Add(backoff(e.fails))
		e.log.Warn("disk: start-failed", "err", err.Error(), "fails", e.fails)
		if e.fails >= failsMax {
			e.set(StateError, "syncthing не запускается")
		} else {
			e.arm(e.nextAt)
			e.set(StateWait, "запуск не удался")
		}
		return
	}
	e.unlock = unlock
	e.set(StateRunning, "")
}

func (e *Engine) evalJoin(ctx context.Context, home string) {
	if e.joining {
		e.set(StateJoining, "")
		return
	}
	if !e.up {
		e.set(StateWait, "канал не поднят")
		return
	}
	if now := time.Now(); now.Before(e.joinNextAt) {
		e.arm(e.joinNextAt)
		e.set(StateWait, "повтор подключения")
		return
	}
	e.joining = true
	jctx, cancel := context.WithCancel(ctx)
	e.joinCancel = cancel
	env := JoinEnv{Home: home, Bin: e.d.Bin, SSH: e.ssh, Log: e.log, Folders: e.d.Cfg.Folders, Base: e.d.Cfg.Base}
	go func() {
		info, err := Join(jctx, env)
		select {
		case e.joinDone <- joinResult{info, err}:
		default:
		}
		e.poke()
	}()
	e.set(StateJoining, "")
}

// ssh выполняет команду на сервере через канал.
func (e *Engine) ssh(ctx context.Context, cmd string, stdin []byte) ([]byte, error) {
	var out, errb bytes.Buffer
	var in io.Reader
	if stdin != nil {
		in = bytes.NewReader(stdin)
	}
	code, err := e.d.Channel.Exec(ctx, cmd, in, &out, &errb)
	if err != nil {
		return nil, err
	}
	if code != 0 {
		return out.Bytes(), fmt.Errorf("ssh: код %d: %s", code, strings.TrimSpace(firstLine(errb.String())))
	}
	return out.Bytes(), nil
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

// lineLog — Writer, пропускающий в журнал только безопасные строки WARN/ERR (не чаще раза в 2 с).
type lineLog struct {
	log  api.Logger
	last time.Time
	pr   *io.PipeWriter
}

func newLineLog(log api.Logger) io.WriteCloser {
	pr, pw := io.Pipe()
	l := &lineLog{log: log, pr: pw}
	go func() {
		sc := bufio.NewScanner(pr)
		for sc.Scan() {
			if t, ok := safeLine(sc.Text()); ok && time.Since(l.last) > 2*time.Second {
				l.last = time.Now()
				log.Warn("disk: syncthing", "line", t)
			}
		}
		_, _ = io.Copy(io.Discard, pr)
	}()
	return pw
}

func (e *Engine) startProc(ctx context.Context, home string) error {
	state := filepath.Join(home, "state")
	if err := os.MkdirAll(state, 0700); err != nil {
		return err
	}
	args := append(append([]string{}, e.d.BinArgs...), "serve", "--home", state, "--no-browser", "--no-restart")
	out := newLineLog(e.log)
	p, err := e.d.Procs.Start(ctx, api.ProcSpec{
		Name: "syncthing", Path: e.d.Bin, Args: args, Dir: home,
		Env: append(os.Environ(), "STMONITORED=yes"), Stdout: out, Stderr: out,
	})
	if err != nil {
		return err
	}
	e.proc, e.procAt, e.procOut = p, time.Now(), out
	return nil
}

func (e *Engine) shutdown() {
	e.stopping = true
	if e.joinCancel != nil {
		e.joinCancel()
	}
	if e.timer != nil {
		e.timer.Stop()
	}
	if e.proc != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		_ = e.proc.Stop(ctx)
		cancel()
		e.proc = nil
		e.closeOut()
	}
	if e.unlock != nil {
		e.unlock()
		e.unlock = nil
	}
	if e.fwd != nil {
		e.fwd.close()
		e.fwd = nil
	}
}

func (e *Engine) closeOut() {
	if e.procOut != nil {
		_ = e.procOut.Close()
		e.procOut = nil
	}
}
