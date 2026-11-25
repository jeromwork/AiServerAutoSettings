// Package forward — проброс через канал (как v2 forward.py и lan.py): точечные порты на 127.0.0.1 ПК, expose/unexpose по имени,
// внутренний SOCKS для sing-box LAN, проверка сетей ЛВС.
// Слушатели только 127.0.0.1. Канала нет — входящее закрывается сразу. Системную сеть/прокси/реестр не трогаем.
package forward

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"remoteagents/internal/api"
)

const connMax = 256

var exposeReserved = map[int]bool{47831: true}

type handler func(c net.Conn, s *sess) error

type listener struct {
	name string
	port int
	ok   bool
	err  string
	ln   net.Listener
	h    handler
	excl bool
}

type target struct {
	host string
	port int
}

type fwd struct {
	cfg  *api.Config
	ch   api.Channel
	log  api.Logger
	mode api.Mode
	path string // State/exposed.json

	mu        sync.Mutex // listeners, fixed, exposed, static, nets
	listeners map[string]*listener
	fixed     map[string]target
	exposed   map[string]api.Exposed
	exposedL  map[string]int
	static    []*listener
	nets      []lanNet
	internal  string

	cmu     sync.Mutex // conns, up, sctx, refused, count, lan
	conns   map[net.Conn]struct{}
	up      bool
	session int
	sctx    context.Context
	cancel  context.CancelFunc
	refused []string
	count   int
	lan     map[string]*lanState
	lanOrd  []string

	sem  chan struct{}
	done chan struct{}
	stop context.CancelFunc
}

func New(cfg *api.Config, ch api.Channel, p api.Paths, log api.Logger, tr api.Traces, mode api.Mode) (api.Forwarder, error) {
	f := &fwd{cfg: cfg, ch: ch, log: log.With("forward"), mode: mode, path: filepath.Join(p.State, "exposed.json"),
		listeners: map[string]*listener{}, fixed: map[string]target{}, exposed: map[string]api.Exposed{}, exposedL: map[string]int{},
		conns: map[net.Conn]struct{}{}, lan: map[string]*lanState{}, sem: make(chan struct{}, connMax), done: make(chan struct{})}
	f.nets = withServer(parseNets(cfg), cfg)
	f.loadExposed()
	return f, nil
}

func (f *fwd) Name() string { return "forward" }

func (f *fwd) Start(ctx context.Context) error {
	ctx, f.stop = context.WithCancel(context.Background())
	f.mu.Lock()
	if !f.mode.Safe {
		fw, ok := f.cfg.Forwards, f.cfg.Forwards != nil
		if !ok {
			if w := f.cfg.Happier.LocalWeb; w != nil && w.Enabled && w.Port != 0 && w.ServerPort != 0 {
				fw = []api.ForwardCfg{{Listen: w.Port, ToHost: "127.0.0.1", ToPort: w.ServerPort}}
			}
		}
		for i, x := range fw {
			if i >= 16 {
				break
			}
			if x.Listen < 1 || x.Listen > 65535 || x.ToHost == "" || x.ToPort < 1 {
				f.log.Warn("bad.config", "item", fmt.Sprint(x), "why", "пропущен: нужны listen и to=host:port")
				continue
			}
			x := x
			l := &listener{name: fmt.Sprintf("forward:%d", x.Listen), port: x.Listen,
				h: func(c net.Conn, s *sess) error { return f.forward(c, s, x.ToHost, x.ToPort) }}
			f.static = append(f.static, l)
		}
		f.retryStaticLocked()
		if l := f.listenLocked(&listener{name: "internalSocks", h: f.internalSocks}); l.ok {
			f.internal = fmt.Sprintf("127.0.0.1:%d", l.port)
		}
	}
	f.mu.Unlock()
	if f.ch != nil {
		go f.watch(ctx)
	}
	return nil
}

func (f *fwd) Stop(ctx context.Context) error {
	if f.stop != nil {
		f.stop()
	}
	f.channelDown()
	f.mu.Lock()
	for _, l := range f.listeners {
		if l.ln != nil {
			l.ln.Close()
		}
	}
	f.listeners = map[string]*listener{}
	f.mu.Unlock()
	return nil
}

// watch: события канала (подписка), не опрос.
func (f *fwd) watch(ctx context.Context) {
	ch, cancel := f.ch.Subscribe()
	defer cancel()
	f.onState(f.ch.State())
	for {
		select {
		case <-ctx.Done():
			return
		case st, ok := <-ch:
			if !ok {
				return
			}
			f.onState(st)
		}
	}
}

func (f *fwd) onState(st api.ChannelState) {
	f.cmu.Lock()
	was, sess := f.up, f.session
	f.cmu.Unlock()
	if st.State != "up" {
		if was {
			f.channelDown()
		}
		return
	}
	if was && sess == st.Session {
		return
	}
	if was {
		f.channelDown()
	}
	f.channelUp(st.Session)
}

func (f *fwd) channelUp(session int) {
	f.cmu.Lock()
	f.up, f.session = true, session
	f.sctx, f.cancel = context.WithCancel(context.Background())
	sctx := f.sctx
	f.cmu.Unlock()
	f.mu.Lock()
	// v2 retried busy static ports every 10 s; retry here only on a new channel up.
	f.retryStaticLocked()
	f.restoreExposedLocked()
	f.mu.Unlock()
	f.startLan(sctx, session)
}

func (f *fwd) channelDown() {
	f.cmu.Lock()
	cancel := f.cancel
	f.up, f.cancel, f.sctx = false, nil, nil
	conns := f.conns
	f.conns = map[net.Conn]struct{}{}
	for _, s := range f.lan {
		if s.status == "checking" {
			s.status = "cancelled"
		}
	}
	f.cmu.Unlock()
	if cancel != nil {
		cancel()
	}
	for c := range conns { // закрытие сокета завершает блокирующий pipe
		c.Close()
	}
}

func (f *fwd) retryStaticLocked() {
	for _, l := range f.static {
		if cur := f.listeners[l.name]; cur == nil || !cur.ok {
			f.listenLocked(l)
		}
	}
}

func (f *fwd) listenLocked(l *listener) *listener {
	if cur := f.listeners[l.name]; cur != nil && cur.ok {
		return cur
	}
	lc := net.ListenConfig{}
	if l.excl {
		lc.Control = exclusiveControl
	}
	ln, err := lc.Listen(context.Background(), "tcp4", fmt.Sprintf("127.0.0.1:%d", l.port))
	n := &listener{name: l.name, port: l.port, h: l.h, excl: l.excl}
	f.listeners[l.name] = n
	if err != nil {
		n.err = err.Error()
		f.log.Warn("bind.failed", "name", l.name, "port", l.port, "err", n.err)
		return n
	}
	n.ok, n.ln, n.port = true, ln, ln.Addr().(*net.TCPAddr).Port
	f.log.Info("listen", "name", l.name, "port", n.port)
	go f.accept(n)
	return n
}

func (f *fwd) accept(l *listener) {
	for {
		c, err := l.ln.Accept()
		if err != nil {
			f.mu.Lock()
			if f.listeners[l.name] == l {
				l.ok = false
			}
			f.mu.Unlock()
			l.ln.Close()
			return
		}
		f.mu.Lock()
		cur := f.listeners[l.name] == l
		f.mu.Unlock()
		if !cur {
			c.Close()
			return
		}
		select {
		case f.sem <- struct{}{}:
			go f.run(c, l.h)
		default:
			c.Close()
		}
	}
}

// sess — сокеты, открытые обработчиком этого соединения.
type sess struct {
	f   *fwd
	ups []net.Conn
}

func (f *fwd) track(c net.Conn) {
	f.cmu.Lock()
	f.conns[c] = struct{}{}
	f.cmu.Unlock()
}

func (s *sess) reg(c net.Conn) {
	s.f.track(c)
	s.ups = append(s.ups, c)
}

func (f *fwd) run(c net.Conn, h handler) {
	f.track(c)
	f.cmu.Lock()
	f.count++
	f.cmu.Unlock()
	s := &sess{f: f}
	defer func() {
		f.cmu.Lock()
		delete(f.conns, c)
		for _, u := range s.ups {
			delete(f.conns, u)
		}
		f.cmu.Unlock()
		for _, u := range s.ups {
			u.Close()
		}
		c.Close()
		<-f.sem
	}()
	if err := h(c, s); err != nil {
		f.refuse("соединение", err)
	}
}

func (f *fwd) refuse(what string, err error) {
	f.cmu.Lock()
	f.refused = append(f.refused, what+": "+err.Error())
	if len(f.refused) > 5 {
		f.refused = f.refused[len(f.refused)-5:]
	}
	f.cmu.Unlock()
	msg := err.Error()
	if len(msg) > 100 {
		msg = msg[:100]
	}
	f.log.Warn("refused", "what", what, "why", msg)
}

// dial — через канал; канала нет — ошибка сразу.
func (f *fwd) dial(host string, port int) (net.Conn, error) {
	f.cmu.Lock()
	ctx := f.sctx
	f.cmu.Unlock()
	if ctx == nil || f.ch == nil {
		return nil, errors.New("канал не работает")
	}
	return f.ch.DialContext(ctx, "tcp", net.JoinHostPort(host, fmt.Sprint(port)))
}

func (f *fwd) forward(c net.Conn, s *sess, host string, port int) error {
	up, err := f.dial(host, port)
	if err != nil {
		return err
	}
	s.reg(up)
	pipe(c, up)
	return nil
}

func (f *fwd) fixedForward(c net.Conn, s *sess, key string) error {
	f.mu.Lock()
	t, ok := f.fixed[key]
	f.mu.Unlock()
	if !ok {
		return nil
	}
	return f.forward(c, s, t.host, t.port)
}

// ---- expose ----

func validPort(p int) error {
	if p < 1 || p > 65535 {
		return errors.New("порт должен быть целым числом от 1 до 65535")
	}
	return nil
}

func validName(n string) error {
	bad := len(n) == 0 || utf8.RuneCountInString(n) > 128
	for _, r := range n {
		if r < 32 || r == 127 {
			bad = true
		}
	}
	if bad || strings.TrimSpace(n) == "" {
		return errors.New("нужно непустое имя до 128 символов без управляющих символов")
	}
	return nil
}

// pickPCPort: желаемый порт и следующие 20, кроме служебных и busy. Bind проверяет вызывающий.
func pickPCPort(want int, busy map[int]bool) (int, error) {
	last := min(want+20, 65535)
	for p := want; p <= last; p++ {
		if !busy[p] && !exposeReserved[p] {
			return p, nil
		}
	}
	return 0, fmt.Errorf("нет свободного порта ПК в диапазоне %d–%d", want, last)
}

func (f *fwd) loadExposed() {
	b, err := os.ReadFile(f.path)
	if err != nil {
		if !os.IsNotExist(err) {
			f.log.Warn("expose.load.failed", "err", err.Error())
		}
		return
	}
	var rows []api.Exposed
	if err := json.Unmarshal(b, &rows); err != nil {
		f.log.Warn("expose.load.failed", "err", err.Error())
		return
	}
	for _, r := range rows {
		if validName(r.Name) != nil || validPort(r.ServerPort) != nil || validPort(r.PCPort) != nil {
			f.log.Warn("expose.load.failed", "err", "плохая запись", "name", r.Name)
			f.exposed = map[string]api.Exposed{}
			return
		}
		f.exposed[r.Name] = api.Exposed{Name: r.Name, ServerPort: r.ServerPort, PCPort: r.PCPort}
	}
}

func (f *fwd) saveExposed() error {
	rows := make([]api.Exposed, 0, len(f.exposed))
	for _, r := range f.exposed {
		rows = append(rows, r)
	}
	b, err := json.MarshalIndent(rows, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(f.path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(f.path), "exposed-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err = tmp.Write(b); err == nil {
		err = tmp.Sync()
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	return os.Rename(tmp.Name(), f.path)
}

func (f *fwd) restoreExposedLocked() {
	for _, r := range f.exposed {
		if _, err := f.exposeLocked(r.Name, r.ServerPort, r.PCPort); err != nil {
			f.log.Warn("expose.restore.failed", "name", r.Name, "err", err.Error())
		}
	}
}

func (f *fwd) Expose(name string, serverPort, pcPort int) (api.Exposed, error) {
	if err := validName(name); err != nil {
		return api.Exposed{}, err
	}
	if err := validPort(serverPort); err != nil {
		return api.Exposed{}, err
	}
	if pcPort != 0 {
		if err := validPort(pcPort); err != nil {
			return api.Exposed{}, err
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.exposeLocked(name, serverPort, pcPort)
}

func (f *fwd) exposeLocked(name string, serverPort, pcPort int) (api.Exposed, error) {
	old, hadOld := f.exposed[name]
	want := pcPort
	if want == 0 {
		want = serverPort
		if hadOld {
			want = old.PCPort
		}
	}
	busy := map[int]bool{}
	for _, l := range f.listeners {
		if l.ok {
			busy[l.port] = true
		}
	}
	for n, r := range f.exposed {
		if n != name {
			busy[r.PCPort] = true
		}
	}
	oldKey := fmt.Sprintf("forward:%d", old.PCPort)
	owned := hadOld && f.exposedL[name] == old.PCPort && f.listeners[oldKey] != nil && f.listeners[oldKey].ok
	if owned {
		delete(busy, old.PCPort)
	}
	var port int
	for {
		p, err := pickPCPort(want, busy)
		if err != nil {
			return api.Exposed{}, err
		}
		if f.addForwardLocked(p, "127.0.0.1", serverPort) {
			port = p
			break
		}
		delete(f.listeners, fmt.Sprintf("forward:%d", p))
		busy[p] = true
	}
	f.exposed[name] = api.Exposed{Name: name, ServerPort: serverPort, PCPort: port}
	if err := f.saveExposed(); err != nil {
		if hadOld {
			f.exposed[name] = old
			if owned && port == old.PCPort {
				f.fixed[oldKey] = target{"127.0.0.1", old.ServerPort}
			}
		} else {
			delete(f.exposed, name)
		}
		if !owned || port != old.PCPort {
			f.removeForwardLocked(port)
		}
		return api.Exposed{}, err
	}
	if owned && port != old.PCPort {
		f.removeForwardLocked(old.PCPort)
	}
	f.exposedL[name] = port
	res := f.exposed[name]
	f.log.Info("expose", "name", name, "serverPort", serverPort, "pcPort", port)
	return res, nil
}

func (f *fwd) Unexpose(name string) error {
	if err := validName(name); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	old, had := f.exposed[name]
	delete(f.exposed, name)
	if err := f.saveExposed(); err != nil {
		if had {
			f.exposed[name] = old
		}
		return err
	}
	if had && f.exposedL[name] == old.PCPort {
		f.removeForwardLocked(old.PCPort)
	}
	f.log.Info("unexpose", "name", name)
	return nil
}

func (f *fwd) List() []api.Exposed {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.listLocked()
}

func (f *fwd) listLocked() []api.Exposed {
	out := make([]api.Exposed, 0, len(f.exposed))
	for _, r := range f.exposed {
		l := f.listeners[fmt.Sprintf("forward:%d", r.PCPort)]
		if f.exposedL[r.Name] != r.PCPort || l == nil || !l.ok {
			r.Err = "не слушает"
			if l != nil && l.err != "" {
				r.Err = l.err
			}
		}
		out = append(out, r)
	}
	return out
}

// addForwardLocked: фиксированный проброс 127.0.0.1:listen -> host:port через канал; повторный вызов меняет только цель.
// Слушатель эксклюзивный (SO_EXCLUSIVEADDRUSE на Windows): занятый порт честно даёт ошибку. true, если слушатель открыт.
func (f *fwd) addForwardLocked(listen int, host string, port int) bool {
	key := fmt.Sprintf("forward:%d", listen)
	cur := f.listeners[key]
	if _, fixed := f.fixed[key]; fixed && cur != nil && cur.ok {
		f.fixed[key] = target{host, port}
		return true
	}
	if cur != nil && cur.ok {
		return false // порт принадлежит статическому forwards, не менять его цель
	}
	f.fixed[key] = target{host, port}
	l := f.listenLocked(&listener{name: key, port: listen, excl: true,
		h: func(c net.Conn, s *sess) error { return f.fixedForward(c, s, key) }})
	if !l.ok {
		delete(f.fixed, key)
	}
	return l.ok
}

func (f *fwd) removeForwardLocked(listen int) {
	key := fmt.Sprintf("forward:%d", listen)
	delete(f.fixed, key)
	l := f.listeners[key]
	delete(f.listeners, key)
	for n, p := range f.exposedL {
		if p == listen {
			delete(f.exposedL, n)
		}
	}
	if l != nil && l.ln != nil {
		l.ln.Close()
	}
}

func (f *fwd) InternalSocks() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.internal
}

func (f *fwd) Status() map[string]any {
	f.mu.Lock()
	ls := map[string]any{}
	for k, l := range f.listeners {
		m := map[string]any{"port": l.port, "ok": l.ok}
		if l.err != "" {
			m["error"] = l.err
		}
		ls[k] = m
	}
	exposed := f.listLocked()
	var nets []string
	for _, n := range f.nets {
		nets = append(nets, n.name)
	}
	f.mu.Unlock()
	f.cmu.Lock()
	defer f.cmu.Unlock()
	return map[string]any{"channel_up": f.up, "listeners": ls, "connections": len(f.conns), "total": f.count,
		"exposed": exposed, "nets": nets, "refused": append([]string(nil), f.refused...), "lan": f.lanStatusLocked(time.Now())}
}
