package singbox

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"remoteagents/internal/api"
	"remoteagents/internal/bus"
	"remoteagents/internal/procs"
)

type Options struct {
	Mode                          api.Mode
	Instance, LockJSON, RawConfig string // retained constructor compatibility; no v3 lock/intent files
	LANSocks                      func() string
	Bus                           *bus.Bus
	Binary                        string
	// Network supplies the platform's current VPN interface. Called on start/net.changed.
	Network func() string
}
type request struct {
	kind  string
	ctx   context.Context
	reply chan error
}
type controller struct {
	mu                                      sync.Mutex
	cfg                                     *api.Config
	paths                                   api.Paths
	log                                     api.Logger
	pr                                      api.Procs
	o                                       Options
	bus                                     *bus.Bus
	events                                  chan bus.Event
	requests                                chan request
	ctx                                     context.Context
	cancel                                  context.CancelFunc
	unsub                                   []func()
	ready                                   chan struct{}
	readyOnce                               sync.Once
	running, up, failed, stopping, relaunch bool
	fails, bindRetries                      int
	lines                                   *logLines
	process                                 api.Process
	candidates                              []api.ChannelPath
	ports                                   map[string]int
	clashPort                               int
	secret                                  string
	tail                                    []string
	traffic                                 object
	trafficCancel                           context.CancelFunc
}

var ansi = regexp.MustCompile(`\x1b\[[0-9;]*m`)
var bindError = regexp.MustCompile(`(?i)bind:|listen (tcp|udp)|address already in use|forbidden by its access permissions`)

func New(cfg *api.Config, p api.Paths, log api.Logger, _ api.Traces, pr api.Procs, o Options) (api.Singbox, error) {
	if cfg == nil {
		return nil, errors.New("singbox: нет настроек")
	}
	b := o.Bus
	if b == nil {
		b = bus.New(log)
	}
	if pr == nil {
		pr = procs.New(log, b)
	}
	if log != nil {
		log = log.With("singbox")
	}
	return &controller{cfg: cfg, paths: p, log: log, pr: pr, o: o, bus: b, ready: make(chan struct{}), ports: map[string]int{}, traffic: object{"up_bps": int64(0), "down_bps": int64(0), "active": false}}, nil
}
func (s *controller) Name() string           { return "singbox" }
func (s *controller) Ready() <-chan struct{} { return s.ready }
func (s *controller) ChanAddr() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ports["chan"] == 0 {
		return ""
	}
	return fmt.Sprintf("127.0.0.1:%d", s.ports["chan"])
}
func (s *controller) PathAddr(name string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ports[name] == 0 {
		return ""
	}
	return fmt.Sprintf("127.0.0.1:%d", s.ports[name])
}
func (s *controller) PathNames() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	names := []string{}
	for _, p := range s.candidates {
		if p.Name != "chan" {
			names = append(names, p.Name)
		}
	}
	return names
}
func (s *controller) Effective() api.Effective { return api.Effective{} }
func (s *controller) Status() map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return object{"up": s.up, "failed": s.failed, "restarts": s.fails, "paths": len(s.candidates), "traffic": clone(s.traffic)}
}
func (s *controller) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.running {
		return nil
	}
	s.ctx, s.cancel = context.WithCancel(ctx)
	s.events = make(chan bus.Event, 1000)
	s.requests = make(chan request)
	s.running = true
	s.stopping = false
	for _, topic := range []string{"settings.loaded", "proc.exited", "singbox.exited", "singbox.line", "net.changed", "app.stop"} {
		s.unsub = append(s.unsub, s.bus.Subscribe(topic, func(ev bus.Event) {
			select {
			case s.events <- ev:
			case <-s.ctx.Done():
			}
		}))
	}
	go s.loop()
	return nil
}
func (s *controller) Stop(ctx context.Context) error {
	return s.request(request{kind: "stop", ctx: ctx})
}
func (s *controller) Apply(ctx context.Context, e api.Effective) error {
	if e.LAN || e.VPN {
		return errors.New("singbox: TUN запускается только через vpnrun")
	}
	return s.request(request{kind: "apply", ctx: ctx})
}
func (s *controller) request(r request) error {
	s.mu.Lock()
	if !s.running {
		s.mu.Unlock()
		return nil
	}
	done := s.ctx.Done()
	requests := s.requests
	s.mu.Unlock()
	r.reply = make(chan error, 1)
	select {
	case requests <- r:
	case <-done:
		return nil
	case <-r.ctx.Done():
		return r.ctx.Err()
	}
	select {
	case err := <-r.reply:
		return err
	case <-done:
		return nil
	case <-r.ctx.Done():
		return r.ctx.Err()
	}
}
func (s *controller) loop() {
	s.mu.Lock()
	s.launch()
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.running = false
		for _, u := range s.unsub {
			u()
		}
		s.unsub = nil
		s.mu.Unlock()
	}()
	for {
		select {
		case <-s.ctx.Done():
			s.mu.Lock()
			s.stopping = true
			s.stopProcess(context.Background())
			s.mu.Unlock()
			return
		case r := <-s.requests:
			s.mu.Lock()
			var err error
			if r.kind == "stop" {
				s.stopping = true
				err = s.stopProcess(r.ctx)
				s.cancel()
			} else {
				s.reset()
				err = s.restart(r.ctx)
			}
			s.mu.Unlock()
			r.reply <- err
			if r.kind == "stop" {
				return
			}
		case ev := <-s.events:
			s.mu.Lock()
			s.handle(ev)
			quit := s.stopping
			s.mu.Unlock()
			if quit {
				s.cancel()
				return
			}
		}
	}
}
func (s *controller) reset() { s.failed = false; s.fails = 0; s.bindRetries = 0 }
func (s *controller) stopProcess(ctx context.Context) error {
	if s.trafficCancel != nil {
		s.trafficCancel()
		s.trafficCancel = nil
	}
	s.up = false
	if s.process != nil {
		return s.process.Stop(ctx)
	}
	return nil
}
func (s *controller) restart(ctx context.Context) error {
	if s.process != nil {
		s.relaunch = true
		return s.stopProcess(ctx)
	}
	s.launch()
	return nil
}
func (s *controller) handle(ev bus.Event) {
	switch ev.Topic {
	case "app.stop":
		s.stopping = true
		_ = s.stopProcess(context.Background())
	case "settings.loaded":
		if cfg, ok := ev.Data["config"].(*api.Config); ok {
			s.cfg = cfg
		}
		s.reset()
		_ = s.restart(s.ctx)
	case "net.changed":
		// Like settings.py: rebuild only if the available VPN/proxy paths changed.
		vpn := ""
		if s.o.Network != nil {
			vpn = s.o.Network()
		}
		paths, _ := BuildPaths(s.cfg, localProxies(s.ctx, s.cfg), vpn)
		before, _ := json.Marshal(s.candidates)
		after, _ := json.Marshal(paths)
		if s.failed || !bytes.Equal(before, after) {
			s.reset()
			_ = s.restart(s.ctx)
		}
	case "singbox.line":
		if ev.Data["owner"] != s {
			return
		}
		line := str(ev.Data["line"])
		s.tail = append(s.tail, line[max(0, len(line)-200):])
		if len(s.tail) > 8 {
			s.tail = s.tail[len(s.tail)-8:]
		}
		if strings.Contains(line, "sing-box started") {
			s.reset()
			s.up = true
			s.readyOnce.Do(func() { close(s.ready) })
			s.bus.Publish("singbox.started", object{"paths": len(s.candidates)})
			s.startTraffic()
		}
	case "proc.exited":
		if ev.Data["name"] != "singbox" || s.process == nil || num(ev.Data["pid"]) != s.process.PID() {
			return
		}
		if s.lines != nil {
			_ = s.lines.Close()
		}
		s.process = nil
		s.up = false
		if s.trafficCancel != nil {
			s.trafficCancel()
		}
		s.bus.Publish("singbox.exited", object{"code": ev.Data["code"]})
	case "singbox.exited":
		if s.stopping {
			return
		}
		if s.relaunch {
			s.relaunch = false
			s.reset()
			s.launch()
			return
		}
		tail := strings.Join(s.tail, " | ")
		if bindError.MatchString(tail) && s.bindRetries < 8 {
			s.bindRetries++
			s.info("bind.retry", "n", s.bindRetries)
			s.launch()
			return
		}
		s.fails++
		if s.fails >= 5 {
			s.failed = true
			s.bus.Publish("singbox.failed", object{"reason": fmt.Sprintf("%d запусков подряд без started: %s", s.fails, tail[max(0, len(tail)-300):])})
		} else {
			s.info("restart", "n", s.fails, "code", ev.Data["code"])
			s.launch()
		}
	}
}
func (s *controller) info(event string, kv ...any) {
	if s.log != nil {
		s.log.Info(event, kv...)
	}
}
func (s *controller) launch() {
	if s.stopping || s.o.Mode.NoSingbox || len(s.cfg.Paths.Channel) == 0 || len(s.cfg.Servers) == 0 || len(s.cfg.Servers[0].Key) == 0 {
		return
	}
	fail := func(err error) {
		s.up = false
		s.info("launch.failed", "error", err)
		s.bus.Publish("singbox.exited", object{"error": "launch failed"})
	}
	vpn := ""
	if s.o.Network != nil {
		vpn = s.o.Network()
	}
	var skipped map[string]string
	s.candidates, skipped = BuildPaths(s.cfg, localProxies(s.ctx, s.cfg), vpn)
	if len(s.candidates) == 0 {
		s.failed = true
		s.bus.Publish("singbox.failed", object{"reason": "нет путей", "skipped": skipped})
		return
	}
	if s.log != nil {
		var v any
		_ = json.Unmarshal(s.cfg.Paths.Channel, &v)
		registerSecrets(s.log, v)
		for _, raw := range s.cfg.Paths.Secrets {
			_ = json.Unmarshal(raw, &v)
			registerSecrets(s.log, v)
		}
	}
	ps, err := freePorts(len(s.candidates) + 2)
	if err != nil {
		fail(err)
		return
	}
	s.ports = map[string]int{}
	for i, p := range s.candidates {
		s.ports[p.Name] = ps[i]
	}
	if s.ports["chan"] == 0 {
		s.ports["chan"] = ps[len(ps)-2]
	}
	s.clashPort = ps[len(ps)-1]
	raw := make([]byte, 24)
	if _, err = rand.Read(raw); err != nil {
		fail(err)
		return
	}
	s.secret = base64.RawURLEncoding.EncodeToString(raw)
	if s.log != nil {
		s.log.Secret(s.secret)
	}
	conf, err := Render(api.RenderContext{Cfg: s.cfg, Paths: s.candidates, Ports: s.ports, ChanPort: s.ports["chan"], ClashPort: s.clashPort, ClashSecret: s.secret})
	if err != nil {
		fail(err)
		return
	}
	dir := filepath.Join(s.paths.Home, "private")
	if err = os.MkdirAll(dir, 0700); err != nil {
		fail(err)
		return
	}
	cfg := filepath.Join(dir, "singbox.json")
	if err = privateWrite(cfg, conf); err != nil {
		fail(err)
		return
	}
	exe := s.o.Binary
	if exe == "" {
		exe, err = FindBinary(s.cfg, s.paths)
		if err != nil {
			fail(err)
			return
		}
	}
	exe = ownCopy(exe, s.paths, s.log)
	s.tail = nil
	w := &logLines{s: s}
	s.lines = w
	s.process, err = s.pr.Start(s.ctx, api.ProcSpec{Name: "singbox", Path: exe, Args: []string{"run", "-c", cfg}, Dir: dir, Stdout: io.Discard, Stderr: w})
	if err != nil {
		_ = w.Close()
		fail(err)
	}
}
func privateWrite(path string, b []byte) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(b)
	e := f.Close()
	if err != nil {
		return err
	}
	return e
}
func registerSecrets(log api.Logger, v any) {
	switch x := v.(type) {
	case map[string]any:
		for k, v := range x {
			if contains([]string{"password", "uuid", "private_key", "private_key_password", "secret", "hy2", "hy2_obfs", "tuic", "tuic_uuid", "trojan", "vless_uuid", "ws_uuid", "shadowtls", "ss"}, k) {
				if s, ok := v.(string); ok {
					log.Secret(s)
				}
			}
			registerSecrets(log, v)
		}
	case []any:
		for _, v := range x {
			registerSecrets(log, v)
		}
	}
}

type logLines struct {
	s   *controller
	mu  sync.Mutex
	buf []byte
}

func (w *logLines) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		w.line(w.buf[:i])
		w.buf = w.buf[i+1:]
	}
	return len(p), nil
}
func (w *logLines) line(b []byte) {
	line := ansi.ReplaceAllString(strings.TrimRight(string(b), "\r"), "")
	if w.s.log != nil {
		w.s.log.Info("sb.line", "line", line)
	}
	w.s.bus.Publish("singbox.line", object{"owner": w.s, "line": line})
}
func (w *logLines) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.buf) > 0 {
		w.line(w.buf)
		w.buf = nil
	}
	return nil
}

// Clash uses action timeouts; streaming traffic has its own connection lifetime.
var clashClient = &http.Client{}
