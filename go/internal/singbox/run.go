package singbox

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"remoteagents/internal/api"
)

type Options struct {
	Mode               api.Mode
	Instance, LockJSON string
	LANSocks           func() string
	RawConfig          string
}

type box struct {
	mu             sync.Mutex
	control        sync.Mutex
	opCancel       context.CancelFunc
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
	running        bool
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
	ports := make([]int, 2)
	for i := range ports {
		l, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
		if err != nil {
			return nil, fmt.Errorf("singbox: port: %w", err)
		}
		ports[i] = l.Addr().(*net.TCPAddr).Port
		if err = l.Close(); err != nil {
			return nil, fmt.Errorf("singbox: port: %w", err)
		}
	}
	if ports[0] == ports[1] {
		return nil, fmt.Errorf("singbox: port: allocation collision")
	}
	return &box{cfg: cfg, p: p, log: log, tr: tr, pr: pr, o: o, ready: make(chan struct{}), rc: api.RenderContext{Cfg: cfg, Mode: o.Mode, Instance: o.Instance, ChanPort: ports[0], ClashPort: ports[1], ClashSecret: token}}, nil
}
func (s *box) Name() string             { return "singbox" }
func (s *box) Ready() <-chan struct{}   { s.mu.Lock(); defer s.mu.Unlock(); return s.ready }
func (s *box) ChanAddr() string         { return fmt.Sprintf("127.0.0.1:%d", s.rc.ChanPort) }
func (s *box) Effective() api.Effective { s.mu.Lock(); defer s.mu.Unlock(); return s.rc.Effective }
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
	s.mu.Lock()
	defer s.mu.Unlock()
	return map[string]any{"running": s.running, "effective": s.rc.Effective, "chan": s.ChanAddr()}
}

func (s *box) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.running {
		return nil
	}
	ctx, cancel := s.operation(ctx)
	defer cancel()
	lock := s.o.LockJSON
	if lock == "" {
		lock = filepath.Join("third_party", "singbox.lock.json")
	}
	binary, err := installBinary(ctx, s.p, s.tr, lock)
	if err != nil {
		return err
	}
	s.binary = binary
	return s.apply(ctx, s.rc.Effective)
}
func (s *box) Apply(ctx context.Context, e api.Effective) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.binary == "" {
		return fmt.Errorf("singbox: stopped: start before apply")
	}
	ctx, cancel := s.operation(ctx)
	defer cancel()
	return s.apply(ctx, e)
}
func (s *box) render(e api.Effective) ([]byte, error) {
	rc := s.rc
	rc.Effective = e
	if s.o.LANSocks != nil {
		rc.LANSocks = s.o.LANSocks()
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
	check, err := s.pr.Start(ctx, api.ProcSpec{Name: "singbox-check", Path: s.binary, Args: []string{"check", "-c", path}, Stream: api.StreamSB})
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
func (s *box) launch(ctx context.Context, e api.Effective) error {
	life, cancel := context.WithCancel(context.WithoutCancel(ctx))
	s.control.Lock()
	if ctx.Err() != nil {
		s.control.Unlock()
		cancel()
		return fmt.Errorf("singbox: start: %w", ctx.Err())
	}
	s.liveCancel = cancel
	s.control.Unlock()
	proc, err := s.pr.Start(life, api.ProcSpec{Name: "singbox", Path: s.binary, Args: []string{"run", "-c", s.config}, Stream: api.StreamSB})
	s.control.Lock()
	s.live = proc
	s.control.Unlock()
	if err != nil {
		cancel()
		return fmt.Errorf("singbox: start: %w", err)
	}
	s.proc = proc
	s.cancel = cancel
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for {
		if err = s.Clash(ctx, "GET", "/version", nil, nil); err == nil {
			s.running = true
			s.rc.Effective = e
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
			return fmt.Errorf("singbox: start: exit %d", proc.ExitCode())
		case <-ctx.Done():
			cancel()
			_ = proc.Stop(ctx)
			return fmt.Errorf("singbox: ready: %w", ctx.Err())
		case <-tick.C:
		}
	}
}
func (s *box) watch(ctx context.Context, p api.Process, e api.Effective) {
	select {
	case <-ctx.Done():
		return
	case <-p.Done():
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.proc != p || ctx.Err() != nil {
		return
	}
	s.running = false
	select {
	case <-s.ready:
		s.ready = make(chan struct{})
	default:
	}
	if e.VPN || e.LAN {
		retry, cancel := s.operation(context.WithoutCancel(ctx))
		defer cancel()
		if err := s.apply(retry, api.Effective{}); err != nil {
			s.log.Error("singbox.fallback", "error", err)
		}
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
	return nil
}
func (s *box) Stop(ctx context.Context) error {
	s.control.Lock()
	s.stopping++
	defer func() { s.control.Lock(); s.stopping--; s.control.Unlock() }()
	if s.opCancel != nil {
		s.opCancel()
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
func (s *box) secrets(value any) {
	switch v := value.(type) {
	case string:
		if v != "" {
			s.log.Secret(v)
		}
	case []any:
		for _, item := range v {
			s.secrets(item)
		}
	case map[string]any:
		for _, item := range v {
			s.secrets(item)
		}
	}
}
