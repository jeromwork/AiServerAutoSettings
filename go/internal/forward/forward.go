package forward

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"remoteagents/internal/api"
)

const (
	connMax        = 256
	defaultProxyPt = 17891
	happierPort    = 47831
)

type listenerEntry struct {
	name     string
	port     int
	ln       net.Listener
	ok       bool
	err      string
	isExpose bool
}

type staticTarget struct {
	name   string
	listen int
	toHost string
	toPort int
}

// Forwarder implements api.Forwarder.
type Forwarder struct {
	cfg   *api.Config
	ch    api.Channel
	paths api.Paths
	log   api.Logger
	tr    api.Traces
	mode  api.Mode

	lifecycle sync.Mutex
	traceMu   sync.Mutex
	traceIDs  map[int]string
	traceSeq  uint64
	mu        sync.RWMutex
	started   bool
	closed    bool
	ctx       context.Context
	cancel    context.CancelFunc
	wg        sync.WaitGroup
	sem       chan struct{}
	retryStop chan struct{}

	activeCount int64
	totalCount  int64

	listeners map[string]*listenerEntry
	exposed   map[string]api.Exposed
	nets      []lanNetwork

	staticTargets []staticTarget
	lanProxyPort  int
	pacScript     []byte

	internalSocksAddr string
	internalSocksLn   net.Listener

	chConnsMu sync.Mutex
	chConns   map[net.Conn]struct{}
}

func New(cfg *api.Config, ch api.Channel, p api.Paths, log api.Logger, tr api.Traces, mode api.Mode) (api.Forwarder, error) {
	ctx, cancel := context.WithCancel(context.Background())

	f := &Forwarder{
		cfg:       cfg,
		ch:        ch,
		paths:     p,
		log:       log,
		tr:        tr,
		mode:      mode,
		ctx:       ctx,
		cancel:    cancel,
		sem:       make(chan struct{}, connMax),
		retryStop: make(chan struct{}),
		listeners: make(map[string]*listenerEntry),
		exposed:   make(map[string]api.Exposed),
		chConns:   make(map[net.Conn]struct{}),
		traceIDs:  make(map[int]string),
	}

	f.nets = parseNets(cfg)

	// Determine proxy port
	f.lanProxyPort = defaultProxyPt
	if cfg != nil && cfg.LanProxy != nil && cfg.LanProxy.Port > 0 {
		f.lanProxyPort = cfg.LanProxy.Port
	}
	f.pacScript = []byte(pacText(f.nets, f.lanProxyPort))

	// Configure static forwards if not in Safe mode
	if !mode.Safe && cfg != nil {
		if len(cfg.Forwards) > 0 {
			for _, fwd := range cfg.Forwards {
				if fwd.Listen > 0 && fwd.ToPort > 0 {
					name := fmt.Sprintf("forward:%d", fwd.Listen)
					f.staticTargets = append(f.staticTargets, staticTarget{
						name:   name,
						listen: fwd.Listen,
						toHost: fwd.ToHost,
						toPort: fwd.ToPort,
					})
				}
			}
		} else if cfg.Happier.LocalWeb != nil && cfg.Happier.LocalWeb.Enabled && cfg.Happier.LocalWeb.Port > 0 && cfg.Happier.LocalWeb.ServerPort > 0 {
			name := fmt.Sprintf("forward:%d", cfg.Happier.LocalWeb.Port)
			f.staticTargets = append(f.staticTargets, staticTarget{
				name:   name,
				listen: cfg.Happier.LocalWeb.Port,
				toHost: "127.0.0.1",
				toPort: cfg.Happier.LocalWeb.ServerPort,
			})
		}
	}

	// Load existing exposed configurations
	f.loadExposed()

	return f, nil
}

func (f *Forwarder) Name() string {
	return "forward"
}

func (f *Forwarder) Start(ctx context.Context) error {
	f.lifecycle.Lock()
	defer f.lifecycle.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	f.mu.Lock()
	if f.started || f.closed {
		f.mu.Unlock()
		return nil
	}
	f.started = true
	f.mu.Unlock()

	// If not in Safe mode, start internal SOCKS, static forwards, and lanProxy
	if !f.mode.Safe {
		f.startInternalSocks()
		f.startStaticForwards()
		f.startLanProxy()

		// Start retry loop for static forwards that failed to bind
		f.wg.Add(1)
		go f.retryStaticLoop()
	}

	// Restore exposed forward listeners
	f.restoreExposed()

	context.AfterFunc(ctx, func() {
		stopCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		_ = f.Stop(stopCtx)
	})
	// Watch channel state changes
	f.wg.Add(1)
	go f.watchChannelState()

	return nil
}

func (f *Forwarder) Stop(ctx context.Context) error {
	f.lifecycle.Lock()
	defer f.lifecycle.Unlock()
	f.mu.Lock()
	if f.closed {
		f.mu.Unlock()
		return nil
	}
	f.closed = true
	f.cancel()
	close(f.retryStop)

	// Close internal socks
	if f.internalSocksLn != nil {
		_ = f.internalSocksLn.Close()
		f.recordTraceDone(f.internalSocksLn.Addr().(*net.TCPAddr).Port)
		f.internalSocksLn = nil
	}

	// Close all listeners
	for name, l := range f.listeners {
		if l.ln != nil {
			_ = l.ln.Close()
			f.recordTraceDone(l.port)
		}
		delete(f.listeners, name)
	}
	f.mu.Unlock()

	// Close active channel connections
	f.closeAllChannelConns()

	done := make(chan struct{})
	go func() { f.wg.Wait(); close(done) }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (f *Forwarder) Status() map[string]any {
	f.mu.RLock()
	defer f.mu.RUnlock()

	listenersMap := make(map[string]map[string]any, len(f.listeners))
	for k, v := range f.listeners {
		listenersMap[k] = map[string]any{
			"port": v.port,
			"ok":   v.ok,
			"err":  v.err,
		}
	}

	exposedList := make([]api.Exposed, 0, len(f.exposed))
	for _, v := range f.exposed {
		exp := v
		key := fmt.Sprintf("expose:%s", exp.Name)
		if l, ok := f.listeners[key]; !ok || !l.ok {
			exp.Err = "not-listening"
		}
		exposedList = append(exposedList, exp)
	}

	return map[string]any{
		"listeners":      listenersMap,
		"exposed":        exposedList,
		"connections":    atomic.LoadInt64(&f.activeCount),
		"total":          atomic.LoadInt64(&f.totalCount),
		"internal_socks": f.internalSocksAddr,
	}
}

func (f *Forwarder) InternalSocks() string {
	f.mu.RLock()
	defer f.mu.RUnlock()
	if f.mode.Safe {
		return ""
	}
	return f.internalSocksAddr
}

func (f *Forwarder) List() []api.Exposed {
	f.mu.RLock()
	defer f.mu.RUnlock()

	res := make([]api.Exposed, 0, len(f.exposed))
	for _, exp := range f.exposed {
		key := fmt.Sprintf("expose:%s", exp.Name)
		if l, ok := f.listeners[key]; !ok || !l.ok {
			exp.Err = "not-listening"
		}
		res = append(res, exp)
	}
	return res
}

func (f *Forwarder) Expose(name string, serverPort, pcPort int) (api.Exposed, error) {
	if err := validName(name); err != nil {
		return api.Exposed{}, err
	}
	if serverPort < 1 || serverPort > 65535 {
		return api.Exposed{}, fmt.Errorf("forward: invalid-port: serverPort must be 1..65535, got %d", serverPort)
	}
	if pcPort != 0 && (pcPort < 1 || pcPort > 65535) {
		return api.Exposed{}, fmt.Errorf("forward: invalid-port: pcPort must be 1..65535, got %d", pcPort)
	}

	f.mu.Lock()
	defer f.mu.Unlock()

	if f.closed {
		return api.Exposed{}, errors.New("forward: stopped: component is closed")
	}
	old, exists := f.exposed[name]
	want := serverPort
	if pcPort != 0 {
		want = pcPort
	} else if exists {
		want = old.PCPort
	}

	busy := make(map[int]bool)
	for n, exp := range f.exposed {
		if n != name {
			busy[exp.PCPort] = true
		}
	}
	for _, l := range f.listeners {
		if l.ok && (!exists || l.port != old.PCPort) {
			busy[l.port] = true
		}
	}

	var chosenPort int
	var chosenLn net.Listener
	var bindErr error

	maxPort := want + 20
	if maxPort > 65535 {
		maxPort = 65535
	}

	for p := want; p <= maxPort; p++ {
		if busy[p] || f.isReservedPort(p) {
			continue
		}
		if exists && old.PCPort == p {
			if l := f.listeners["expose:"+name]; l != nil && l.ok {
				result := api.Exposed{Name: name, ServerPort: serverPort, PCPort: p}
				f.exposed[name] = result
				if err := f.saveExposedLocked(); err != nil {
					f.exposed[name] = old
					return api.Exposed{}, fmt.Errorf("forward: save: %w", err)
				}
				return result, nil
			}
		}
		ln, err := f.listen(p)
		if err != nil {
			busy[p] = true
			bindErr = err
			continue
		}
		chosenPort = p
		chosenLn = ln
		bindErr = nil
		break
	}

	if chosenLn == nil {
		if bindErr != nil {
			return api.Exposed{}, fmt.Errorf("forward: no-port: range %d-%d busy: %w", want, maxPort, bindErr)
		}
		return api.Exposed{}, fmt.Errorf("forward: no-port: range %d-%d busy", want, maxPort)
	}

	result := api.Exposed{Name: name, ServerPort: serverPort, PCPort: chosenPort}
	f.exposed[name] = result
	if err := f.saveExposedLocked(); err != nil {
		if exists {
			f.exposed[name] = old
		} else {
			delete(f.exposed, name)
		}
		_ = chosenLn.Close()
		f.recordTraceDone(chosenPort)
		return api.Exposed{}, fmt.Errorf("forward: save: %w", err)
	}
	oldKey := "expose:" + name
	if oldL := f.listeners[oldKey]; oldL != nil && oldL.ln != nil {
		_ = oldL.ln.Close()
		f.recordTraceDone(oldL.port)
	}
	lEntry := &listenerEntry{name: oldKey, port: chosenPort, ln: chosenLn, ok: true, isExpose: true}
	f.listeners[oldKey] = lEntry
	f.wg.Add(1)
	go f.serveForwardConn(lEntry, "127.0.0.1", serverPort)
	f.log.Info("forward: expose", "name", name, "serverPort", serverPort, "pcPort", chosenPort)

	return result, nil
}

func (f *Forwarder) Unexpose(name string) error {
	if err := validName(name); err != nil {
		return err
	}

	f.mu.Lock()
	defer f.mu.Unlock()

	old, exists := f.exposed[name]
	if !exists {
		return nil
	}

	delete(f.exposed, name)
	if err := f.saveExposedLocked(); err != nil {
		f.exposed[name] = old
		return fmt.Errorf("forward: save: %w", err)
	}
	key := fmt.Sprintf("expose:%s", name)
	if l, ok := f.listeners[key]; ok {
		if l.ln != nil {
			_ = l.ln.Close()
			f.recordTraceDone(l.port)
		}
		delete(f.listeners, key)
	}

	f.log.Info("forward: unexpose", "name", name, "pcPort", old.PCPort)

	return nil
}

func (f *Forwarder) isReservedPort(p int) bool {
	if p == happierPort || p == defaultProxyPt || p == f.lanProxyPort {
		return true
	}
	if f.cfg != nil && f.cfg.Happier.LocalWeb != nil && f.cfg.Happier.LocalWeb.Port == p {
		return true
	}
	return false
}

func (f *Forwarder) startInternalSocks() {
	f.mu.Lock()
	defer f.mu.Unlock()
	ln, err := f.listen(0)
	if err != nil {
		f.log.Warn("forward: internal-socks-failed", "err", err)
		return
	}
	f.internalSocksLn = ln
	f.internalSocksAddr = ln.Addr().String()

	f.wg.Add(1)
	go func() {
		defer f.wg.Done()
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			if !f.acquireSem() {
				_ = conn.Close()
				continue
			}
			f.wg.Add(1)
			go func(c net.Conn) {
				defer f.wg.Done()
				defer f.releaseSem()
				stop := context.AfterFunc(f.ctx, func() { _ = c.Close() })
				defer stop()
				defer f.unregisterConn(c)
				defer func() { _ = c.Close() }()

				serveSOCKS5(f.ctx, c, c, func(ctx context.Context, target string) (net.Conn, error) {
					if f.ch.State().State != "up" {
						return nil, errors.New("forward: channel-down: channel is not up")
					}
					up, err := f.ch.DialContext(ctx, "tcp", target)
					if err != nil {
						return nil, err
					}
					f.registerChConn(c, up)
					return &trackedConn{Conn: up, f: f}, nil
				})
			}(conn)
		}
	}()
}

func (f *Forwarder) startStaticForwards() {
	f.mu.Lock()
	defer f.mu.Unlock()

	for _, st := range f.staticTargets {
		f.tryBindStaticLocked(st)
	}
}

func (f *Forwarder) tryBindStaticLocked(st staticTarget) {
	if l, ok := f.listeners[st.name]; ok && l.ok {
		return
	}

	ln, err := f.listen(st.listen)
	if err != nil {
		f.listeners[st.name] = &listenerEntry{
			name: st.name,
			port: st.listen,
			ok:   false,
			err:  err.Error(),
		}
		f.log.Warn("forward: bind-failed", "name", st.name, "port", st.listen, "err", err)
		return
	}

	entry := &listenerEntry{
		name: st.name,
		port: st.listen,
		ln:   ln,
		ok:   true,
	}
	f.listeners[st.name] = entry
	f.log.Info("forward: listen", "name", st.name, "port", st.listen)

	f.wg.Add(1)
	go f.serveForwardConn(entry, st.toHost, st.toPort)
}

func (f *Forwarder) startLanProxy() {
	f.mu.Lock()
	defer f.mu.Unlock()

	name := "lanProxy"
	if l, ok := f.listeners[name]; ok && l.ok {
		return
	}

	if f.closed {
		return
	}
	ln, err := f.listen(f.lanProxyPort)
	if err != nil {
		f.listeners[name] = &listenerEntry{
			name: name,
			port: f.lanProxyPort,
			ok:   false,
			err:  err.Error(),
		}
		f.log.Warn("forward: bind-failed", "name", name, "port", f.lanProxyPort, "err", err)
		return
	}

	entry := &listenerEntry{
		name: name,
		port: f.lanProxyPort,
		ln:   ln,
		ok:   true,
	}
	f.listeners[name] = entry
	f.log.Info("forward: listen", "name", name, "port", f.lanProxyPort)

	f.wg.Add(1)
	go func() {
		defer f.wg.Done()
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			if !f.acquireSem() {
				_ = conn.Close()
				continue
			}
			f.wg.Add(1)
			go func(c net.Conn) {
				defer f.wg.Done()
				defer f.releaseSem()
				stop := context.AfterFunc(f.ctx, func() { _ = c.Close() })
				defer stop()
				defer f.unregisterConn(c)
				defer func() { _ = c.Close() }()

				serveDualProxy(f.ctx, c, f.pacScript, func(ctx context.Context, target string) (net.Conn, error) {
					host, _, err := parseHostPort(target)
					if err != nil {
						host = target
					}

					// Route matching: if matches LAN net -> via channel; else direct
					matchedNet := matchLAN(f.nets, host)
					if matchedNet != "" {
						if f.ch.State().State != "up" {
							return nil, errors.New("forward: channel-down: channel is not up")
						}
						up, err := f.ch.DialContext(ctx, "tcp", target)
						if err != nil {
							return nil, err
						}
						f.registerChConn(c, up)
						f.log.Info("forward: lan-route", "net", matchedNet, "target", target)
						return &trackedConn{Conn: up, f: f}, nil
					}

					var d net.Dialer
					d.Timeout = 10 * time.Second
					return d.DialContext(ctx, "tcp", target)
				})
			}(conn)
		}
	}()
}

func (f *Forwarder) retryStaticLoop() {
	defer f.wg.Done()
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-f.retryStop:
			return
		case <-ticker.C:
			f.mu.Lock()
			if f.closed {
				f.mu.Unlock()
				return
			}
			// Retry static targets
			for _, st := range f.staticTargets {
				if l, ok := f.listeners[st.name]; !ok || !l.ok {
					f.tryBindStaticLocked(st)
				}
			}
			// Retry lanProxy
			if l, ok := f.listeners["lanProxy"]; !ok || !l.ok {
				f.mu.Unlock()
				f.startLanProxy()
				f.mu.Lock()
			}
			f.mu.Unlock()
		}
	}
}

func (f *Forwarder) serveForwardConn(entry *listenerEntry, toHost string, toPort int) {
	defer f.wg.Done()
	ln := entry.ln
	targetAddr := net.JoinHostPort(toHost, strconv.Itoa(toPort))

	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}

		if !f.acquireSem() {
			_ = conn.Close()
			continue
		}

		f.wg.Add(1)
		go func(c net.Conn) {
			defer f.wg.Done()
			defer f.releaseSem()
			stop := context.AfterFunc(f.ctx, func() { _ = c.Close() })
			defer stop()
			defer f.unregisterConn(c)
			defer func() { _ = c.Close() }()

			if f.ch.State().State != "up" {
				return
			}

			f.mu.RLock()
			target := targetAddr
			if entry.isExpose {
				target = net.JoinHostPort("127.0.0.1", strconv.Itoa(f.exposed[strings.TrimPrefix(entry.name, "expose:")].ServerPort))
			}
			f.mu.RUnlock()
			up, err := f.ch.DialContext(f.ctx, "tcp", target)
			if err != nil {
				return
			}
			defer func() { _ = up.Close() }()

			f.registerChConn(c, up)
			defer f.unregisterConn(up)
			pipe(f.ctx, c, up)
		}(conn)
	}
}

func (f *Forwarder) restoreExposed() {
	f.mu.Lock()
	defer f.mu.Unlock()

	if f.closed {
		return
	}
	rows := make([]api.Exposed, 0, len(f.exposed))
	for _, exp := range f.exposed {
		rows = append(rows, exp)
	}
	f.mu.Unlock()
	for _, exp := range rows {
		if _, err := f.Expose(exp.Name, exp.ServerPort, exp.PCPort); err != nil {
			f.log.Warn("forward: expose-restore-failed", "name", exp.Name, "err", err)
		}
	}
	f.mu.Lock()
}

func (f *Forwarder) watchChannelState() {
	defer f.wg.Done()
	stateCh, cancel := f.ch.Subscribe()
	defer cancel()

	for {
		select {
		case <-f.retryStop:
			return
		case st, ok := <-stateCh:
			if !ok {
				return
			}
			if st.State == "up" {
				f.restoreExposed()
			} else {
				// Channel is not up - close all active connections routed through the channel
				f.closeAllChannelConns()
			}
		}
	}
}

func (f *Forwarder) registerChConn(c, up net.Conn) {
	f.chConnsMu.Lock()
	if f.ctx.Err() != nil || f.ch.State().State != "up" {
		_ = c.Close()
		_ = up.Close()
		f.chConnsMu.Unlock()
		return
	}
	f.chConns[c] = struct{}{}
	f.chConns[up] = struct{}{}
	f.chConnsMu.Unlock()
}

func (f *Forwarder) closeAllChannelConns() {
	f.chConnsMu.Lock()
	conns := make([]net.Conn, 0, len(f.chConns))
	for c := range f.chConns {
		conns = append(conns, c)
	}
	f.chConns = make(map[net.Conn]struct{})
	f.chConnsMu.Unlock()

	for _, c := range conns {
		_ = c.Close()
	}
}

func (f *Forwarder) acquireSem() bool {
	select {
	case f.sem <- struct{}{}:
		atomic.AddInt64(&f.totalCount, 1)
		atomic.AddInt64(&f.activeCount, 1)
		return true
	default:
		return false
	}
}

func (f *Forwarder) releaseSem() {
	<-f.sem
	atomic.AddInt64(&f.activeCount, -1)
}

func (f *Forwarder) loadExposed() {
	path := filepath.Join(f.paths.State, "exposed.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}

	var rows []api.Exposed
	if err := json.Unmarshal(data, &rows); err != nil {
		f.log.Warn("forward: exposed-load-failed", "err", err)
		return
	}

	for _, r := range rows {
		if validName(r.Name) == nil && r.ServerPort >= 1 && r.ServerPort <= 65535 && r.PCPort >= 1 && r.PCPort <= 65535 {
			f.exposed[r.Name] = api.Exposed{
				Name:       r.Name,
				ServerPort: r.ServerPort,
				PCPort:     r.PCPort,
			}
		}
	}
}

func (f *Forwarder) saveExposedLocked() error {
	if err := os.MkdirAll(f.paths.State, 0700); err != nil {
		return err
	}

	list := make([]api.Exposed, 0, len(f.exposed))
	for _, exp := range f.exposed {
		list = append(list, api.Exposed{
			Name:       exp.Name,
			ServerPort: exp.ServerPort,
			PCPort:     exp.PCPort,
		})
	}

	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}

	tmpFile, err := os.CreateTemp(f.paths.State, "exposed-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmpFile.Name()
	defer func() {
		if tmpName != "" {
			_ = os.Remove(tmpName)
		}
	}()

	if _, err := tmpFile.Write(data); err != nil {
		_ = tmpFile.Close()
		return err
	}
	if err := tmpFile.Sync(); err != nil {
		_ = tmpFile.Close()
		return err
	}
	if err := tmpFile.Close(); err != nil {
		return err
	}

	targetPath := filepath.Join(f.paths.State, "exposed.json")
	if err := os.Rename(tmpName, targetPath); err != nil {
		return err
	}
	tmpName = "" // Prevent removal after successful rename

	// Fsync parent directory
	if dir, err := os.Open(f.paths.State); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}

	return nil
}

func (f *Forwarder) listen(port int) (net.Listener, error) {
	id := fmt.Sprintf("forward-%d", atomic.AddUint64(&f.traceSeq, 1))
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	if f.tr != nil {
		if err := f.tr.Intent(api.Trace{Kind: "listener", ID: id, Owner: "forward", Instance: f.tr.Instance(), Data: map[string]string{"addr": addr}}); err != nil {
			return nil, fmt.Errorf("forward: trace-intent: %w", err)
		}
	}
	var lc net.ListenConfig
	ln, err := lc.Listen(f.ctx, "tcp", addr)
	if err != nil {
		if f.tr != nil {
			_ = f.tr.Done("listener", id)
		}
		return nil, err
	}
	if f.tr != nil {
		if err = f.tr.Applied("listener", id, map[string]string{"addr": ln.Addr().String()}, nil); err != nil {
			_ = ln.Close()
			_ = f.tr.Done("listener", id)
			return nil, err
		}
	}
	f.traceMu.Lock()
	f.traceIDs[ln.Addr().(*net.TCPAddr).Port] = id
	f.traceMu.Unlock()
	return ln, nil
}

func (f *Forwarder) recordTraceDone(port int) {
	if f.tr == nil {
		return
	}
	f.traceMu.Lock()
	id := f.traceIDs[port]
	delete(f.traceIDs, port)
	f.traceMu.Unlock()
	_ = f.tr.Done("listener", id)
}

func validName(name string) error {
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 128 {
		return fmt.Errorf("forward: invalid-name: length must be 1..128 characters")
	}
	for _, c := range name {
		if c < 32 || c == 127 {
			return fmt.Errorf("forward: invalid-name: contains control characters")
		}
	}
	return nil
}

func (f *Forwarder) unregisterConn(c net.Conn) {
	f.chConnsMu.Lock()
	delete(f.chConns, c)
	f.chConnsMu.Unlock()
}

type trackedConn struct {
	net.Conn
	f *Forwarder
}

func (c *trackedConn) Close() error { c.f.unregisterConn(c.Conn); return c.Conn.Close() }

// Preserve TCP half-close through the connection tracking wrapper.
func (c *trackedConn) CloseWrite() error {
	if cw, ok := c.Conn.(closeWriter); ok {
		return cw.CloseWrite()
	}
	return c.Close()
}
