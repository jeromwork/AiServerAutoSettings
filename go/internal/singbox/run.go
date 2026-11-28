package singbox

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/config"
	"remoteagents/internal/platform"
)

// RoleVPN — отдельный экземпляр sing-box только для VPN (свой процесс, конфиг, clash-порт и адаптер ra3-<id>-vpn).
// Включить = Apply(VPN:true) запускает процесс, выключить = Apply(VPN:false) останавливает; канал и ЛВС не затрагиваются.
const RoleVPN = "vpn"

type Options struct {
	Role               string // "" — основной (канал + ЛВС); RoleVPN — только VPN
	Mode               api.Mode
	Instance, LockJSON string
	LANSocks           func() string
	RawConfig          string
	OnTunCrash         func(api.Effective) // sing-box с TUN упал (откат без TUN уже запущен)
	OnEvent            func(kind string)   // события из журнала канального sing-box (EvNetworkChanged, EvOutboundError)
	DefaultIface       func() string       // физический внешний интерфейс сейчас ("" — не определён)
	VPNBlock           func() bool         // VPN перекрыт (vpn.lockExit + сбой); nil — нет
	VPNSplit           func() int          // длина нарезки маршрутов VPN (этап 1b); nil/0 — без нарезки
}

type box struct {
	pmu            sync.Mutex
	procs          map[api.Process]struct{} // живые процессы (счётчик, уборка забытых)
	mu             sync.Mutex
	control        sync.Mutex
	opCancel       context.CancelFunc
	recCancel      context.CancelFunc // прерывает ожидание автоперезапуска при Stop
	live           api.Process
	liveCancel     context.CancelFunc
	stopping       int
	cfg            *api.Config
	p              api.Paths
	log            api.Logger
	tr             api.Traces
	pr             api.Procs
	o              Options
	proc           api.Process
	cancel         context.CancelFunc
	ready          chan struct{}
	rc             api.RenderContext
	binary, config string
	binSource      string
	binErr         string
	running        bool

	// Снимок для чтения без s.mu: Start держит s.mu до 150 с (загрузка/запуск), а Status/Ready/Effective
	// зовут страница и канал — они не должны ждать.
	vmu       sync.Mutex
	vReady    chan struct{}
	vRunning  bool
	vEff      api.Effective
	vSource   string
	vErr      string
	vStart    bool
	applyHook func(context.Context) error                // тесты
	crashes   int                                        // подряд упавших запусков без длительной работы (для задержки перезапуска)
	restart   func(context.Context, api.Effective) error // тесты: замена apply при автоперезапуске
	sleep     func(context.Context, time.Duration) bool  // тесты: ожидание задержки (false — отменено)
	vpnExe    string                                     // копия sing-box для VPN (RoleVPN)
	vChan     int                                        // порты входов: меняются при повторном выборе, читаются без s.mu
	vClash    int
	pp        pathPorts // входы по одному на путь: параллельная «гонка» путей канала (см. channel/race.go)
}

// pathPorts — стабильные локальные порты входов по путям (имя пути → порт). Порт выбирается при первом рендере и живёт
// до смены/перезапуска коробки; при занятости портом — сбрасывается и выбирается заново.
type pathPorts struct {
	mu sync.Mutex
	m  map[string]int
}

func (pp *pathPorts) port(name string) int {
	pp.mu.Lock()
	defer pp.mu.Unlock()
	if v, ok := pp.m[name]; ok {
		return v
	}
	ports, err := allocPorts(1)
	if err != nil {
		return 0
	}
	for _, v := range pp.m {
		if v == ports[0] {
			return 0
		}
	}
	if pp.m == nil {
		pp.m = map[string]int{}
	}
	pp.m[name] = ports[0]
	return ports[0]
}

func (pp *pathPorts) get(name string) int {
	pp.mu.Lock()
	defer pp.mu.Unlock()
	return pp.m[name]
}

// busy — какой-либо порт путей уже занят посторонним (bind не проходит): набор нужно выбрать заново.
func (pp *pathPorts) busy() bool {
	pp.mu.Lock()
	defer pp.mu.Unlock()
	for _, v := range pp.m {
		if bindCheck(v) != nil {
			return true
		}
	}
	return false
}

func (pp *pathPorts) reset() {
	pp.mu.Lock()
	pp.m = nil
	pp.mu.Unlock()
}

func New(cfg *api.Config, p api.Paths, log api.Logger, tr api.Traces, pr api.Procs, o Options) (api.Singbox, error) {
	if cfg == nil || log == nil || tr == nil || pr == nil {
		return nil, fmt.Errorf("singbox: dependencies: missing dependency")
	}
	if o.Mode.NoSingbox {
		return nil, fmt.Errorf("singbox: disabled: no-singbox mode")
	}
	if o.Instance == "" {
		o.Instance = tr.Instance()
	}
	if len(o.Instance) != 32 {
		return nil, fmt.Errorf("singbox: instance: expected 32 hex characters")
	}
	if _, err := hex.DecodeString(o.Instance); err != nil {
		return nil, fmt.Errorf("singbox: instance: invalid hex")
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return nil, fmt.Errorf("singbox: random: %w", err)
	}
	token := hex.EncodeToString(secret)
	log.Secret(token)
	ports, err := allocPorts(2)
	if err != nil {
		return nil, err
	}
	ready := make(chan struct{})
	b := &box{cfg: cfg, p: p, log: log, tr: tr, pr: pr, o: o, ready: ready, vReady: ready, vChan: ports[0], vClash: ports[1], rc: api.RenderContext{Cfg: cfg, Mode: o.Mode, Instance: o.Instance, ChanPort: ports[0], ClashPort: ports[1], ClashSecret: token}}
	b.rc.PathPort = b.pp.port
	return b, nil
}

// PathAddr — локальный вход sing-box, ведущий прямо в путь name (минуя селектор chan); "" — входа нет.
func (s *box) PathAddr(name string) string {
	if p := s.pp.get(name); p > 0 {
		return fmt.Sprintf("127.0.0.1:%d", p)
	}
	return ""
}
func (s *box) isVPN() bool { return s.o.Role == RoleVPN }
func (s *box) Name() string {
	if s.isVPN() {
		return "singbox-vpn"
	}
	return "singbox"
}
func (s *box) Ready() <-chan struct{} { s.vmu.Lock(); defer s.vmu.Unlock(); return s.vReady }
func (s *box) ChanAddr() string {
	s.vmu.Lock()
	defer s.vmu.Unlock()
	return fmt.Sprintf("127.0.0.1:%d", s.vChan)
}
func (s *box) Effective() api.Effective { s.vmu.Lock(); defer s.vmu.Unlock(); return s.vEff }
func (s *box) view(f func())            { s.vmu.Lock(); f(); s.vmu.Unlock() }
func (s *box) PathNames() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, err := s.render(s.rc.Effective)
	if err != nil {
		return nil
	}
	var config struct {
		Outbounds []struct {
			Tag       string
			Outbounds []string
		}
	}
	if json.Unmarshal(data, &config) != nil {
		return nil
	}
	var names []string
	for _, outbound := range config.Outbounds {
		if outbound.Tag == "chan" {
			names = append(names, outbound.Outbounds...)
			break
		}
	}
	return names
}
func (s *box) Status() map[string]any {
	s.vmu.Lock()
	defer s.vmu.Unlock()
	return map[string]any{"running": s.vRunning, "starting": s.vStart, "effective": s.vEff, "chan": fmt.Sprintf("127.0.0.1:%d", s.vChan), "binary": s.vSource, "binaryError": s.vErr}
}

func (s *box) Start(ctx context.Context) error {
	ctx, deadline := context.WithTimeout(ctx, 150*time.Second)
	defer deadline()
	if err := s.lockState(ctx); err != nil {
		return fmt.Errorf("singbox: start: %w", err)
	}
	defer s.mu.Unlock()
	if s.running {
		return nil
	}
	s.view(func() { s.vStart = true })
	defer s.view(func() { s.vStart = false })
	ctx, cancel := s.operation(ctx)
	defer cancel()
	binary, source, err := installBinary(ctx, s.p, s.log, s.tr)
	if err != nil {
		s.binErr = err.Error()
		s.view(func() { s.vErr = s.binErr })
		s.log.Error("singbox.binary.failed", "err", s.binErr)
		return err
	}
	s.binErr, s.binSource = "", source
	s.view(func() { s.vErr, s.vSource = "", source })
	s.binary = binary
	if s.isVPN() {
		return nil // процесс VPN запускает только Apply(VPN:true)
	}
	return s.startWithPorts(ctx)
}
func (s *box) Apply(ctx context.Context, e api.Effective) error {
	ctx, deadline := context.WithTimeout(ctx, 30*time.Second)
	defer deadline()
	if err := s.lockState(ctx); err != nil {
		return fmt.Errorf("singbox: apply: %w", err)
	}
	defer s.mu.Unlock()
	if s.binary == "" {
		return fmt.Errorf("singbox: stopped: start before apply")
	}
	ctx, cancel := s.operation(ctx)
	defer cancel()
	return s.apply(ctx, e)
}
func (s *box) render(e api.Effective) ([]byte, error) {
	if s.o.DefaultIface != nil {
		s.rc.DefaultIface = s.o.DefaultIface()
	}
	rc := s.rc
	rc.Effective = e
	if s.o.VPNSplit != nil {
		rc.VPNSplit = s.o.VPNSplit()
	}
	rc.VPNBlock = s.o.VPNBlock != nil && s.o.VPNBlock()
	rc.GeoIPPath = filepath.Join(s.p.State, "geoip-ru.srs")
	if s.o.LANSocks != nil {
		rc.LANSocks = s.o.LANSocks()
	}
	if s.isVPN() {
		return RenderVPN(rc)
	}
	if s.o.RawConfig == "" {
		return Render(rc)
	}
	data, err := os.ReadFile(s.o.RawConfig)
	if err != nil {
		return nil, fmt.Errorf("singbox: config: %w", err)
	}
	var raw map[string]any
	if err = json.Unmarshal(data, &raw); err != nil || len(raw) == 0 {
		return nil, fmt.Errorf("singbox: config: invalid JSON")
	}
	// Raw input is for dev only; keep the controller local and authenticated.
	raw["experimental"] = map[string]any{"clash_api": map[string]any{"external_controller": fmt.Sprintf("127.0.0.1:%d", rc.ClashPort), "secret": rc.ClashSecret}}
	if !rc.Mode.AllowsTun() || (!e.VPN && !e.LAN) {
		if ins, ok := raw["inbounds"].([]any); ok {
			out := make([]any, 0, len(ins))
			for _, in := range ins {
				m, ok := in.(map[string]any)
				if !ok || m["type"] != "tun" {
					out = append(out, in)
				}
			}
			raw["inbounds"] = out
		}
	}
	return json.Marshal(raw)
}
func (s *box) apply(ctx context.Context, e api.Effective) error {
	if !s.o.Mode.AllowsTun() {
		e = api.Effective{}
	}
	if s.isVPN() {
		if !e.VPN {
			return s.stopVPN(ctx)
		}
		if err := s.prepareVPN(ctx); err != nil {
			return err
		}
	}
	data, err := s.render(e)
	if err != nil {
		return err
	}
	var values any
	if err = json.Unmarshal(data, &values); err != nil {
		return fmt.Errorf("singbox: config: invalid JSON")
	}
	s.secrets(values)
	path, release, err := tempFile(s.p, s.tr, "config-*.new")
	if err != nil {
		return err
	}
	defer release()
	if err = os.WriteFile(path, data, 0600); err != nil {
		return fmt.Errorf("singbox: config: %w", err)
	}
	check, err := s.pr.Start(ctx, api.ProcSpec{Name: s.Name() + "-check", Path: s.binary, Args: []string{"check", "-c", path}, Stream: api.StreamSB})
	if err != nil {
		return fmt.Errorf("singbox: check: %w", err)
	}
	select {
	case <-check.Done():
		if check.ExitCode() != 0 {
			return fmt.Errorf("singbox: check: exit %d", check.ExitCode())
		}
	case <-ctx.Done():
		_ = check.Stop(ctx)
		return fmt.Errorf("singbox: check: %w", ctx.Err())
	}
	old := s.config
	if err = s.stop(ctx); err != nil {
		return err
	}
	// A unique validated file is published by rename; keep the previous one for rollback.
	target := path + ".json"
	if err = s.tr.Intent(api.Trace{Kind: "tmp", ID: target, Owner: s.Name(), Data: map[string]string{"path": target}}); err != nil {
		return err
	}
	if err = os.Rename(path, target); err != nil {
		return fmt.Errorf("singbox: config: %w", err)
	}
	if err = s.tr.Applied("tmp", target, map[string]string{"path": target}, nil); err != nil {
		_ = s.remove(target)
		return err
	}
	s.config = target
	if err = s.launch(ctx, e); err != nil {
		_ = s.remove(target)
		s.config = old
		if e.VPN || e.LAN {
			return s.apply(ctx, api.Effective{})
		}
		if old != "" {
			if restore := s.launch(ctx, s.rc.Effective); restore != nil {
				return fmt.Errorf("singbox: rollback: %v; restart: %w", restore, err)
			}
		}
		return err
	}
	if old != "" {
		return s.remove(old)
	}
	return nil
}

// adapters — имена TUN-адаптеров, которые поднимет запуск с желаемым состоянием e.
func (s *box) adapters(e api.Effective) (names []string) {
	if !s.o.Mode.AllowsTun() {
		return nil
	}
	if e.VPN && s.isVPN() {
		names = append(names, AdapterName(s.o.Instance, "vpn"))
	}
	if e.LAN && !s.isVPN() {
		names = append(names, AdapterName(s.o.Instance, "lan"))
	}
	return names
}

// traceAdapters записывает намерение ДО запуска sing-box с TUN: упавшее/убитое ядро не оставит адаптер без следа,
// уборка (cleanup startup/exit) снимет его по записи.
func (s *box) traceAdapters(e api.Effective) error {
	for _, n := range s.adapters(e) {
		if err := s.tr.Intent(api.Trace{Kind: "adapter", ID: n, Owner: s.Name(), Data: map[string]string{"name": n}}); err != nil {
			return err
		}
	}
	return nil
}

// sweepVPNLock — убрать остатки правил «только через наш адрес» (nft/ip rule) от мёртвого sing-box; подменяется в тестах.
var sweepVPNLock = platform.SweepVPNLock

func (s *box) sweepLock() {
	if !s.isVPN() {
		return
	}
	if err := sweepVPNLock(context.Background()); err != nil {
		s.log.Warn("singbox.lock-sweep", "err", err.Error())
	}
}

func (s *box) launch(ctx context.Context, e api.Effective) error {
	s.sweepLock() // перед запуском: правила только у живого процесса, остатки прошлого убираем
	if err := s.traceAdapters(e); err != nil {
		return fmt.Errorf("singbox: trace: %w", err)
	}
	life, cancel := context.WithCancel(context.WithoutCancel(ctx))
	s.control.Lock()
	if ctx.Err() != nil {
		s.control.Unlock()
		cancel()
		return fmt.Errorf("singbox: start: %w", ctx.Err())
	}
	s.liveCancel = cancel
	s.control.Unlock()
	so, se := s.outWriters()
	proc, err := s.pr.Start(life, api.ProcSpec{Name: s.Name(), Path: s.exe(), Args: []string{"run", "-c", s.config}, Stream: api.StreamSB, Stdout: so, Stderr: se})
	s.control.Lock()
	s.live = proc
	s.control.Unlock()
	if err != nil {
		cancel()
		return fmt.Errorf("singbox: start: %w", err)
	}
	s.proc = proc
	s.cancel = cancel
	s.track(proc)
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for {
		if err = s.Clash(ctx, "GET", "/version", nil, nil); err == nil {
			s.running = true
			s.rc.Effective = e
			for _, n := range s.adapters(e) {
				_ = s.tr.Applied("adapter", n, map[string]string{"name": n}, nil)
			}
			s.view(func() { s.vRunning, s.vEff = true, e })
			select {
			case <-s.ready:
			default:
				close(s.ready)
			}
			go s.watch(life, proc, e)
			return nil
		}
		select {
		case <-proc.Done():
			cancel()
			return fmt.Errorf("singbox: start: exit %d: %w", proc.ExitCode(), errEarlyExit)
		case <-ctx.Done():
			cancel()
			_ = proc.Stop(ctx)
			return fmt.Errorf("singbox: ready: %w", ctx.Err())
		case <-tick.C:
		}
	}
}

// Границы задержки автоперезапуска sing-box: 0.5 с … 30 с, удваивается, сбрасывается после длительной работы.
const (
	restartMin  = 500 * time.Millisecond
	restartMax  = 30 * time.Second
	restartLive = 30 * time.Second // проработал дольше — прошлые падения не считаются
)

func restartDelay(n int) time.Duration {
	d := restartMin
	for ; n > 0 && d < restartMax; n-- {
		d *= 2
	}
	return min(d, restartMax)
}

func (s *box) watch(ctx context.Context, p api.Process, e api.Effective) {
	started := time.Now()
	select {
	case <-ctx.Done():
		return
	case <-p.Done():
	}
	s.mu.Lock()
	if s.proc != p || ctx.Err() != nil {
		s.mu.Unlock()
		return
	}
	s.running = false
	select {
	case <-s.ready:
		s.ready = make(chan struct{})
	default:
	}
	s.view(func() { s.vRunning, s.vReady = false, s.ready })
	if time.Since(started) > restartLive {
		s.crashes = 0
	}
	s.mu.Unlock()
	s.sweepLock() // процесс умер — его правила (nft redirect на мёртвый порт) не должны резать интернет
	s.log.Error("singbox.exited", "code", p.ExitCode(), "crashes", s.crashes)
	if e.VPN || e.LAN {
		if s.o.OnTunCrash != nil {
			go s.o.OnTunCrash(e)
		}
		e = api.Effective{} // без TUN: прежний откат
	}
	s.recover(ctx, e)
}

// recover перезапускает упавший sing-box с экспоненциальной задержкой, пока не получится или его не остановят/перезапустят иначе.
func (s *box) recover(ctx context.Context, e api.Effective) {
	rctx, rcancel := context.WithCancel(context.Background())
	defer rcancel()
	s.control.Lock()
	s.recCancel = rcancel
	if s.stopping > 0 {
		rcancel()
	}
	s.control.Unlock()
	for {
		d := restartDelay(s.crashes)
		s.crashes++
		s.log.Info("singbox.restart", "in_ms", d.Milliseconds(), "crashes", s.crashes)
		sleep := s.sleep
		if sleep == nil {
			sleep = func(c context.Context, d time.Duration) bool {
				t := time.NewTimer(d)
				defer t.Stop()
				select {
				case <-t.C:
					return true
				case <-c.Done():
					return false
				}
			}
		}
		if !sleep(rctx, d) {
			return
		}
		s.mu.Lock()
		s.control.Lock()
		stopped := s.stopping > 0
		s.control.Unlock()
		if stopped || s.running || s.binary == "" {
			s.mu.Unlock()
			return
		}
		op, cancel := s.operation(context.Background())
		var err error
		if s.restart != nil {
			err = s.restart(op, e)
		} else {
			err = s.apply(op, e)
		}
		cancel()
		s.mu.Unlock()
		if err == nil {
			return
		}
		s.log.Error("singbox.restart-failed", "error", err)
	}
}

func (s *box) stop(ctx context.Context) error {
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
	if s.proc != nil {
		if err := s.proc.Stop(ctx); err != nil {
			return fmt.Errorf("singbox: stop: %w", err)
		}
		s.proc = nil
	}
	s.running = false
	select {
	case <-s.ready:
		s.ready = make(chan struct{})
	default:
	}
	s.view(func() { s.vRunning, s.vReady = false, s.ready })
	return nil
}
func (s *box) Stop(ctx context.Context) error {
	s.control.Lock()
	s.stopping++
	defer func() { s.control.Lock(); s.stopping--; s.control.Unlock() }()
	if s.opCancel != nil {
		s.opCancel()
	}
	if s.recCancel != nil {
		s.recCancel()
	}
	if s.liveCancel != nil {
		s.liveCancel()
	}
	live := s.live
	s.control.Unlock()
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for !s.mu.TryLock() {
		select {
		case <-ctx.Done():
			if live != nil {
				_ = live.Stop(ctx)
			}
			return fmt.Errorf("singbox: stop: %w", ctx.Err())
		case <-tick.C:
		}
	}
	defer s.mu.Unlock()
	if err := s.stop(ctx); err != nil {
		return err
	}
	if s.config != "" {
		if err := s.remove(s.config); err != nil {
			return err
		}
		s.config = ""
	}
	return nil
}
func (s *box) remove(path string) error {
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("singbox: cleanup: %w", err)
	}
	return s.tr.Done("tmp", path)
}

// lockState includes contention in the caller's deadline without a waiting goroutine.
func (s *box) lockState(ctx context.Context) error {
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if s.mu.TryLock() {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.C:
		}
	}
}

// operation lets Stop interrupt work that holds the state lock.
func (s *box) operation(parent context.Context) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithTimeout(parent, 30*time.Second)
	s.control.Lock()
	s.opCancel = cancel
	if s.stopping > 0 {
		cancel()
	}
	s.control.Unlock()
	return ctx, cancel
}

// Register decoded values, including credentials printed separately by sing-box.
func (s *box) secrets(value any) { s.secretsKey(value, "") }

// Имена путей, теги и типы — не секрет (config.PlainKeys), иначе в журнале и на странице они станут `***`.
func (s *box) secretsKey(value any, key string) {
	switch v := value.(type) {
	case string:
		if v != "" && !config.PlainKeys[key] {
			s.log.Secret(v)
		}
	case []any:
		for _, item := range v {
			s.secretsKey(item, key)
		}
	case map[string]any:
		for k, item := range v {
			s.secretsKey(item, k)
		}
	}
}

// errEarlyExit — sing-box вышел до готовности (порт занят/запрещён, ошибка конфига и т.п.).
var errEarlyExit = errors.New("exited before ready")

const portRetries = 5

// bindCheck — реальная проверка порта 127.0.0.1: TCP и UDP (вход direct слушает оба; Windows
// запрещает UDP в зарезервированных диапазонах Hyper-V/Happ, а TCP-проверка этого не видит). Подменяется в тестах.
var bindCheck = func(port int) error {
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	l, err := net.Listen("tcp4", addr)
	if err != nil {
		return err
	}
	_ = l.Close()
	u, err := net.ListenPacket("udp4", addr)
	if err != nil {
		return err
	}
	return u.Close()
}

// allocPorts выбирает n различных портов, проходящих bindCheck.
func allocPorts(n int) ([]int, error) {
	ports := make([]int, 0, n)
	for tries := 0; len(ports) < n && tries < 50; tries++ {
		l, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			return nil, fmt.Errorf("singbox: port: %w", err)
		}
		port := l.Addr().(*net.TCPAddr).Port
		_ = l.Close()
		dup := false
		for _, p := range ports {
			dup = dup || p == port
		}
		if dup || bindCheck(port) != nil {
			continue
		}
		ports = append(ports, port)
	}
	if len(ports) < n {
		return nil, fmt.Errorf("singbox: port: no bindable port found")
	}
	return ports, nil
}

// startWithPorts — apply с повтором на других портах, если sing-box вышел из-за порта.
// Порты перед запуском проверяются реальным bind; после раннего выхода — ещё раз, и при отказе берутся новые.
func (s *box) startWithPorts(ctx context.Context) error {
	var err error
	for attempt := 0; ; attempt++ {
		if bindCheck(s.rc.ChanPort) != nil || bindCheck(s.rc.ClashPort) != nil {
			if err = s.reallocPorts(); err != nil {
				return err
			}
		}
		if s.pp.busy() {
			s.pp.reset()
		}
		if s.applyHook != nil {
			err = s.applyHook(ctx)
		} else {
			err = s.apply(ctx, s.rc.Effective)
		}
		if err == nil || !errors.Is(err, errEarlyExit) || attempt >= portRetries || ctx.Err() != nil {
			return err
		}
		if bindCheck(s.rc.ChanPort) == nil && bindCheck(s.rc.ClashPort) == nil {
			return err // порты в порядке — причина не в них
		}
		s.log.Warn("singbox.port-retry", "attempt", attempt+1)
	}
}

// exe — исполняемый файл процесса: для VPN своя копия RemoteAgents-VPN.exe (процесс VPN отличим от канала по имени).
func (s *box) exe() string {
	if s.isVPN() && s.vpnExe != "" {
		return s.vpnExe
	}
	return s.binary
}

// vpnBinaryName — имя копии sing-box для процесса VPN (без «lab»).
func vpnBinaryName() string {
	if runtime.GOOS == "windows" {
		return vpnNameWin
	}
	return vpnNameNix
}

// prepareVPN — перед запуском процесса VPN: свободный clash-порт и своя копия исполняемого файла.
func (s *box) prepareVPN(ctx context.Context) error {
	if bindCheck(s.rc.ClashPort) != nil {
		if err := s.reallocPorts(); err != nil {
			return err
		}
	}
	if s.vpnExe != "" {
		return nil
	}
	dst := filepath.Join(s.p.Bin, vpnBinaryName())
	want := fileSHA(s.binary)
	if want == "" {
		return fmt.Errorf("singbox: vpn: binary unreadable")
	}
	if fileSHA(dst) != want {
		if err := copyVerified(s.p, s.tr, s.binary, dst, want); err != nil {
			// файл занят остатком прежнего процесса VPN — идём по общему exe (уборка снимет процесс по записи)
			s.log.Warn("singbox.vpn-binary-copy", "err", err.Error())
			return nil
		}
	}
	s.vpnExe = dst
	return nil
}

// stopVPN — выключить VPN: остановить процесс, убрать конфиг; следы адаптера снимет уборка (адаптер исчезает с процессом).
func (s *box) stopVPN(ctx context.Context) error {
	if err := s.stop(ctx); err != nil {
		return err
	}
	if s.config != "" {
		if err := s.remove(s.config); err != nil {
			return err
		}
		s.config = ""
	}
	s.sweepLock()
	s.rc.Effective = api.Effective{}
	s.view(func() { s.vRunning, s.vEff = false, api.Effective{} })
	return nil
}

func (s *box) reallocPorts() error {
	ports, err := allocPorts(2)
	if err != nil {
		return err
	}
	s.rc.ChanPort, s.rc.ClashPort = ports[0], ports[1]
	s.view(func() { s.vChan, s.vClash = ports[0], ports[1] })
	return nil
}

// NetChanged — сеть сменилась (канальный бокс без DefaultIface — ничего не делает: он не привязан к интерфейсу). Интерфейс выхода изменился — перерисовать конфиг и перезапустить (все соединения
// пересоздаются); не изменился — только сбросить зависшие соединения. restarted — был ли перезапуск.
func (s *box) NetChanged(ctx context.Context) (restarted bool, err error) {
	ctx, deadline := context.WithTimeout(ctx, 30*time.Second)
	defer deadline()
	if err = s.lockState(ctx); err != nil {
		return false, fmt.Errorf("singbox: net-changed: %w", err)
	}
	defer s.mu.Unlock()
	if !s.running || s.binary == "" || s.o.DefaultIface == nil {
		return false, nil
	}
	cur, next := s.rc.DefaultIface, s.o.DefaultIface()
	if cur == next {
		cctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		return false, s.Clash(cctx, "DELETE", "/connections", nil, nil)
	}
	ctx, cancel := s.operation(ctx)
	defer cancel()
	if err = s.apply(ctx, s.rc.Effective); err != nil {
		s.rc.DefaultIface = cur
		return false, err
	}
	s.log.Info("singbox.default-iface", "from", cur, "to", next)
	return true, nil
}
