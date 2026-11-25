// Path selection and the active SINGLE round follow v2 uplink.py/rounds.py.
package channel

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/bus"
)

const delayURL = "https://www.gstatic.com/generate_204"
const probeSize = 65536

// Uplink selects chan before an SSH round. Changes arrive from the event bus;
// v2's 30-second delay/check_net loop is replaced by connection/network events.
type Uplink struct {
	mu                           sync.Mutex
	sb                           api.Singbox
	log                          api.Logger
	bus                          *bus.Bus
	onSwitch                     func(path, why string)
	ctx                          context.Context
	cancel                       context.CancelFunc
	unsubs                       []func()
	current                      string
	results                      map[string]*int
	penalties                    map[string]time.Time
	lastTest                     time.Time
	pin                          time.Time
	gen                          int
	busy, pending, up, channelUp bool
}
type uplink = Uplink

func newUplink(sb api.Singbox, log api.Logger, onSwitch func(path, why string)) *uplink {
	return NewUplink(sb, log, nil, onSwitch)
}
func NewUplink(sb api.Singbox, log api.Logger, b *bus.Bus, onSwitch func(path, why string)) *Uplink {
	if b == nil {
		b = bus.New(log)
	}
	if log != nil {
		log = log.With("uplink")
	}
	return &Uplink{sb: sb, log: log, bus: b, onSwitch: onSwitch, results: map[string]*int{}, penalties: map[string]time.Time{}}
}
func (u *Uplink) Name() string { return "uplink" }
func (u *Uplink) Start(ctx context.Context) error {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.cancel != nil {
		return nil
	}
	u.ctx, u.cancel = context.WithCancel(ctx)
	for _, t := range []string{"singbox.started", "singbox.exited", "singbox.failed", "net.changed", "channel.up", "channel.down", "singbox.stream.closed", "path.switch", "app.stop"} {
		u.unsubs = append(u.unsubs, u.bus.Subscribe(t, u.event))
	}
	// Covers startup after sing-box's readiness event, without polling.
	if up, _ := u.sb.Status()["up"].(bool); up {
		u.up = true
		go u.Refresh()
	}
	return nil
}
func (u *Uplink) Stop(context.Context) error {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.cancel != nil {
		u.cancel()
		u.cancel = nil
	}
	u.gen++
	u.up = false
	for _, f := range u.unsubs {
		f()
	}
	u.unsubs = nil
	return nil
}
func (u *Uplink) event(ev bus.Event) {
	switch ev.Topic {
	case "singbox.started":
		u.mu.Lock()
		u.gen++
		u.up = true
		u.current = ""
		u.mu.Unlock()
		u.Refresh()
	case "singbox.exited", "singbox.failed":
		u.mu.Lock()
		u.gen++
		u.current = ""
		u.channelUp = false
		u.up = false
		u.mu.Unlock()
	case "net.changed":
		u.mu.Lock()
		live := u.channelUp
		u.mu.Unlock()
		if !live {
			u.Refresh()
		} else {
			go u.checkCurrent()
		}
	case "channel.up":
		u.mu.Lock()
		u.channelUp = true
		u.mu.Unlock()
	case "singbox.stream.closed":
		go u.checkCurrent()
	case "channel.down":
		u.mu.Lock()
		u.channelUp = false
		u.mu.Unlock()
		if ev.Data["restart"] != true && ev.Data["dropped"] != true {
			u.Refresh()
		}
	case "path.switch":
		go u.Force(fmt.Sprint(ev.Data["path"]))
	case "app.stop":
		_ = u.Stop(context.Background())
	}
}
func (u *Uplink) Current() string { u.mu.Lock(); defer u.mu.Unlock(); return u.current }
func (u *Uplink) Penalize(path string, seconds time.Duration) {
	u.mu.Lock()
	defer u.mu.Unlock()
	u.penalties[path] = time.Now().Add(seconds)
}
func (u *Uplink) Penalized() []string { u.mu.Lock(); defer u.mu.Unlock(); return u.penalized() }
func (u *Uplink) penalized() []string {
	out := []string{}
	for p, t := range u.penalties {
		if time.Now().Before(t) {
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}
func (u *Uplink) Force(path string) bool {
	if !hasName(u.sb.PathNames(), path) {
		return false
	}
	u.mu.Lock()
	if u.ctx == nil || u.ctx.Err() != nil || !u.up {
		u.mu.Unlock()
		return false
	}
	if err := u.sb.Clash(u.ctx, "PUT", "/proxies/chan", map[string]any{"name": path}, nil); err != nil {
		u.mu.Unlock()
		u.info("force.failed", "path", path)
		return false
	}
	u.gen++
	u.current = path
	u.pin = time.Now().Add(600 * time.Second)
	u.mu.Unlock()
	u.info("force", "path", path)
	if u.onSwitch != nil {
		u.onSwitch(path, "команда ассистента: путь "+path)
	}
	u.bus.Publish("uplink.selected", map[string]any{"path": path, "forced": true})
	return true
}
func (u *Uplink) Refresh() {
	u.mu.Lock()
	if u.ctx == nil || u.ctx.Err() != nil || !u.up {
		u.mu.Unlock()
		return
	}
	if u.busy {
		u.pending = true
		u.mu.Unlock()
		return
	}
	u.busy = true
	ctx := u.ctx
	u.mu.Unlock()
	go func() {
		defer func() {
			u.mu.Lock()
			u.busy = false
			pending := u.pending
			u.pending = false
			u.mu.Unlock()
			if pending {
				u.Refresh()
			}
		}()
		u.mu.Lock()
		gen := u.gen
		skip := u.penalized()
		u.mu.Unlock()
		names := []string{}
		for _, n := range u.sb.PathNames() {
			if !hasName(skip, n) {
				names = append(names, n)
			}
		}
		if len(names) == 0 {
			u.info("allfail", "tested", 0, "penalized", skip)
			u.bus.Publish("uplink.failed", map[string]any{"tested": 0})
			return
		}
		result := make([]*int, len(names))
		jobs := make(chan int)
		var wg sync.WaitGroup
		for i := 0; i < min(16, len(names)); i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for i := range jobs {
					result[i] = u.delay(ctx, names[i])
				}
			}()
		}
		for i := range names {
			jobs <- i
		}
		close(jobs)
		wg.Wait()
		u.mu.Lock()
		defer u.mu.Unlock()
		if gen != u.gen || ctx.Err() != nil || !u.up {
			return
		}
		u.results = map[string]*int{}
		u.lastTest = time.Now()
		best := ""
		bestMS := 0
		ok := 0
		for i, n := range names {
			u.results[n] = result[i]
			if ms := result[i]; ms != nil {
				ok++
				if best == "" || *ms < bestMS {
					best = n
					bestMS = *ms
				}
			}
		}
		if best == "" {
			u.info("allfail", "tested", len(names))
			u.bus.Publish("uplink.failed", map[string]any{"tested": len(names)})
			return
		}
		// A manual switch is pinned for automatic checks; a real channel break may still retest.
		if err := u.sb.Clash(ctx, "PUT", "/proxies/chan", map[string]any{"name": best}, nil); err != nil {
			u.info("select.failed", "path", best)
			u.bus.Publish("uplink.failed", map[string]any{"tested": len(names)})
			return
		}
		old := u.current
		u.current = best
		u.bus.Publish("uplink.selected", map[string]any{"path": best, "ms": bestMS, "tested": len(names), "ok": ok})
		if old != "" && old != best && u.onSwitch != nil {
			go u.onSwitch(best, "путь "+old+" -> "+best)
		}
	}()
}
func (u *Uplink) delay(ctx context.Context, path string) *int {
	var out struct {
		Delay *int `json:"delay"`
	}
	err := u.sb.Clash(ctx, "GET", "/proxies/"+url.PathEscape(path)+"/delay?url="+url.QueryEscape(delayURL)+"&timeout=3000", nil, &out)
	if err != nil {
		return nil
	}
	return out.Delay
}
func (u *Uplink) checkCurrent() {
	u.mu.Lock()
	ctx, current, pin, gen := u.ctx, u.current, u.pin, u.gen
	u.mu.Unlock()
	if ctx == nil || current == "" {
		return
	}
	// Two failures are two bounded requests caused by a stream break, not a periodic checker.
	if u.delay(ctx, current) != nil || u.delay(ctx, current) != nil {
		return
	}
	u.mu.Lock()
	valid := gen == u.gen && current == u.current && !time.Now().Before(pin)
	u.mu.Unlock()
	if valid {
		u.Refresh()
	}
}
func (u *Uplink) Status() map[string]any {
	u.mu.Lock()
	defer u.mu.Unlock()
	type item struct {
		name string
		ms   int
	}
	top := []item{}
	for n, ms := range u.results {
		if ms != nil {
			top = append(top, item{n, *ms})
		}
	}
	sort.SliceStable(top, func(i, j int) bool { return top[i].ms < top[j].ms })
	results := map[string]int{}
	for _, x := range top[:min(10, len(top))] {
		results[x.name] = x.ms
	}
	last := 0.0
	if !u.lastTest.IsZero() {
		last = float64(u.lastTest.UnixMilli()) / 1000
	}
	return map[string]any{"current": u.current, "results": results, "penalized": u.penalized(), "last_test": last, "over": u.over()}
}
func (u *Uplink) over() string {
	if strings.HasSuffix(u.current, "-vpn") {
		return "поверх: VPN"
	}
	m := regexp.MustCompile(`socks([0-9]+)$`).FindStringSubmatch(u.current)
	if m != nil {
		return "поверх: прокси 127.0.0.1:" + m[1]
	}
	return "поверх: напрямую"
}
func (u *Uplink) info(event string, kv ...any) {
	if u.log != nil {
		u.log.Info(event, kv...)
	}
}
func hasName(names []string, n string) bool {
	for _, p := range names {
		if p == n {
			return true
		}
	}
	return false
}

// RoundOptions supplies the already running agent and bundled OpenSSH. No OS
// services or elevated user are involved. The platform channel can compose Rounds.
type RoundOptions struct {
	PC, Version, Rollback, SSH, AgentAddr string
	Mode                                  api.Mode
}
type roundEvent struct {
	kind  string
	probe *probe
	data  map[string]any
}
type Rounds struct {
	mu                   sync.Mutex
	cfg                  *api.Config
	sb                   api.Singbox
	agent                api.AgentHost
	paths                api.Paths
	log                  api.Logger
	pr                   api.Procs
	bus                  *bus.Bus
	o                    RoundOptions
	Uplink               *Uplink
	ctx                  context.Context
	cancel               context.CancelFunc
	events               chan roundEvent
	unsubs               []func()
	listener             net.Listener
	probe                *probe
	live                 map[string]*probe
	rn, rcur             int
	up, stopping, closed bool
	channel              map[string]any
	ranking              []map[string]any
	guard                *time.Timer
	pending              bool
}

func NewRounds(cfg *api.Config, sb api.Singbox, agent api.AgentHost, p api.Paths, log api.Logger, pr api.Procs, b *bus.Bus, o RoundOptions) *Rounds {
	if b == nil {
		b = bus.New(log)
	}
	r := &Rounds{cfg: cfg, sb: sb, agent: agent, paths: p, log: log, pr: pr, bus: b, o: o, live: map[string]*probe{}}
	r.Uplink = NewUplink(sb, log, b, func(path, why string) { r.bus.Publish("rounds.drop", map[string]any{"reason": why}) })
	return r
}
func (r *Rounds) Name() string { return "rounds" }
func (r *Rounds) Start(ctx context.Context) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cancel != nil {
		return nil
	}
	if r.cfg == nil || len(r.cfg.Paths.Channel) == 0 || len(r.cfg.Servers) == 0 || len(r.cfg.Servers[0].Key) == 0 || r.o.Mode.NoChannel || r.o.Mode.NoSingbox {
		return nil
	}
	if r.pr == nil || r.agent == nil {
		return errors.New("rounds: нужны procs и агент")
	}
	r.ctx, r.cancel = context.WithCancel(ctx)
	r.events = make(chan roundEvent, 1000)
	r.stopping = false
	if r.o.AgentAddr == "" {
		l, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			r.cancel()
			r.cancel = nil
			return err
		}
		r.listener = l
		r.o.AgentAddr = l.Addr().String()
		go r.agent.Serve(l)
	}
	for _, t := range []string{"singbox.started", "singbox.exited", "singbox.failed", "uplink.selected", "uplink.failed", "net.changed", "proc.exited", "rounds.drop", "app.stop"} {
		r.unsubs = append(r.unsubs, r.bus.Subscribe(t, func(ev bus.Event) { r.send(roundEvent{kind: ev.Topic, data: ev.Data}) }))
	}
	_ = r.Uplink.Start(r.ctx)
	go r.loop()
	if up, _ := r.sb.Status()["up"].(bool); up {
		r.up = true
	}
	r.bus.Publish("agent.ready", map[string]any{"addr": r.o.AgentAddr})
	return nil
}
func (r *Rounds) send(e roundEvent) {
	select {
	case r.events <- e:
	case <-r.ctx.Done():
	}
}
func (r *Rounds) Stop(ctx context.Context) error {
	r.mu.Lock()
	if r.cancel == nil || r.closed {
		r.mu.Unlock()
		return nil
	}
	r.closed = true
	r.stopping = true
	r.cancel()
	if r.guard != nil {
		r.guard.Stop()
	}
	if r.listener != nil {
		r.listener.Close()
	}
	for _, f := range r.unsubs {
		f()
	}
	r.unsubs = nil
	list := []*probe{}
	for _, p := range r.live {
		list = append(list, p)
	}
	r.mu.Unlock()
	_ = r.Uplink.Stop(ctx)
	var errs []error
	for _, p := range list {
		if p.proc != nil {
			errs = append(errs, p.proc.Stop(ctx))
		}
		p.close()
	}
	return errors.Join(errs...)
}
func (r *Rounds) Status() map[string]any {
	r.mu.Lock()
	defer r.mu.Unlock()
	probes := []map[string]any{}
	if r.probe != nil {
		p := r.probe
		p.mu.Lock()
		probes = append(probes, map[string]any{"path": p.path, "state": p.state, "rx": p.rx})
		p.mu.Unlock()
	}
	rows := make([]map[string]any, len(r.ranking))
	for i, x := range r.ranking {
		rows[i] = copyMap(x)
	}
	return map[string]any{"round": r.rn, "sb_up": r.up, "channel": copyMap(r.channel), "finished": r.probe != nil && r.probe.finished, "ranking": rows, "probes": probes}
}
func copyMap(m map[string]any) map[string]any {
	if m == nil {
		return nil
	}
	out := map[string]any{}
	for k, v := range m {
		out[k] = v
	}
	return out
}
func (r *Rounds) ForcePath(name string) error {
	if !r.Uplink.Force(name) {
		return errors.New("rounds: путь неизвестен или selector недоступен")
	}
	return nil
}
func (r *Rounds) loop() {
	defer func() { _ = r.Stop(context.Background()) }()
	for {
		select {
		case <-r.ctx.Done():
			return
		case ev := <-r.events:
			r.mu.Lock()
			r.handle(ev)
			stop := r.stopping
			r.mu.Unlock()
			if stop {
				return
			}
		}
	}
}
func (r *Rounds) handle(ev roundEvent) {
	switch ev.kind {
	case "app.stop":
		r.stopping = true
	case "singbox.started":
		r.up = true
	case "singbox.exited", "singbox.failed":
		r.up = false
		r.drop("sing-box вышел")
	case "uplink.selected":
		if r.channel == nil && (r.probe == nil || r.probe.finished) {
			r.begin("путь выбран")
		}
	case "net.changed":
		if r.channel == nil && r.probe != nil && !r.probe.finished {
			r.drop("смена сети")
		}
	case "rounds.drop":
		if !r.drop(fmt.Sprint(ev.data["reason"])) {
			r.begin(fmt.Sprint(ev.data["reason"]))
		}
	case "probe.ok":
		if ev.probe == r.probe && !ev.probe.finished {
			r.choose(ev.probe)
		}
	case "probe.failed", "round.timeout":
		if ev.probe == r.probe && !ev.probe.finished {
			r.finish(ev.probe, ev.kind == "round.timeout")
			r.stopProbe(ev.probe)
		}
	case "probe.delay":
		if ev.probe == r.probe && len(r.ranking) > 0 {
			r.ranking[0]["delay_ms"] = ev.data["ms"]
			r.save()
		}
	case "probe.up":
		if ev.probe == r.probe && ev.probe.winner {
			r.channel = ev.data
			r.bus.Publish("channel.up", copyMap(ev.data))
		}
	case "proc.exited":
		name, _ := ev.data["name"].(string)
		p := r.live[name]
		if p == nil {
			return
		}
		delete(r.live, name)
		if p.errors != nil {
			p.errors.flush()
		}
		p.close()
		if p != r.probe {
			return
		}
		if p.winner {
			p.mu.Lock()
			wasUp := p.wasUp
			p.mu.Unlock()
			dropped := p.dropped
			r.channel = nil
			r.bus.Publish("channel.down", map[string]any{"path": p.path, "code": ev.data["code"], "reason": p.exitReason(ev.data["code"]), "was_up": wasUp, "dropped": dropped})
			p.finished = true
			if dropped && r.up {
				r.begin("канал сброшен")
			}
		} else if !p.finished {
			reason := p.exitReason(ev.data["code"])
			p.mu.Lock()
			p.reason = "EOF: " + reason
			p.state = "failed"
			p.mu.Unlock()
			r.bus.Publish("path.failed", map[string]any{"name": p.name, "path": p.path, "reason": reason})
			r.finish(p, false)
		}
		if (p.dropped || r.pending) && r.up {
			r.begin("предыдущая ssh-сессия вышла")
		}
	}
}
func (r *Rounds) drop(why string) bool {
	p := r.probe
	if p == nil || p.proc == nil || p.exited() {
		return false
	}
	p.dropped = true
	r.info("channel.drop", "reason", why)
	r.stopProbe(p)
	return true
}
func (r *Rounds) stopProbe(p *probe) {
	if p.proc != nil {
		go func() { _ = p.proc.Stop(context.Background()) }()
	}
}
func (r *Rounds) begin(why string) {
	if !r.up || r.stopping || r.Uplink.Current() == "" || r.sb.ChanAddr() == "" {
		return
	}
	if r.probe != nil && !r.probe.exited() {
		r.pending = true
		return
	}
	r.pending = false
	if r.guard != nil {
		r.guard.Stop()
	}
	r.rn++
	remote := 0
	for i := 0; i < 60; i++ {
		port := 13340 + r.rcur%60
		r.rcur++
		used := false
		for _, p := range r.live {
			if p.rport == port {
				used = true
				break
			}
		}
		if !used {
			remote = port
			break
		}
	}
	if remote == 0 {
		return
	}
	p := &probe{r: r, name: fmt.Sprintf("ssh:%d:chan", r.rn), nonce: randomHex(8), path: "chan", selected: r.Uplink.Current(), rport: remote, state: "run", t0: time.Now(), sha: sha256.New()}
	r.probe = p
	r.live[p.name] = p
	r.bus.Publish("round.begin", map[string]any{"round": r.rn, "paths": 1, "reason": why})
	// A single attempt has a 60-second bound, just like v2's round guard.
	r.guard = time.AfterFunc(60*time.Second, func() { r.send(roundEvent{kind: "round.timeout", probe: p}) })
	if err := r.launch(p); err != nil {
		delete(r.live, p.name)
		p.fail("не запустить ssh")
		r.info("launch.failed", "error", err)
	}
}
func (r *Rounds) launch(p *probe) error {
	if len(r.cfg.Servers) == 0 {
		return errors.New("rounds: нет сервера")
	}
	server := r.cfg.Servers[0]
	private := filepath.Join(r.paths.Home, "private")
	if err := os.MkdirAll(private, 0700); err != nil {
		return err
	}
	key := filepath.Join(private, "channel-key")
	known := filepath.Join(private, "channel-known_hosts")
	if r.log != nil {
		r.log.Secret(string(server.Key))
		r.log.Secret(r.agent.Token())
	}
	if err := writePrivate(key, server.Key); err != nil {
		return err
	}
	hostKey := strings.TrimSpace(strings.ReplaceAll(server.HostKey, "\r", ""))
	fields := strings.Fields(hostKey)
	if len(fields) == 2 {
		hostKey = server.Host + " " + hostKey
	}
	if err := writePrivate(known, []byte(hostKey+"\n")); err != nil {
		return err
	}
	ssh := r.o.SSH
	if ssh == "" {
		name := "ssh"
		if runtime.GOOS == "windows" {
			name = "ssh.exe"
		}
		bundled := filepath.Join(r.paths.Bin, "openssh", name)
		if st, err := os.Stat(bundled); err == nil && st.Mode().IsRegular() {
			ssh = bundled
		} else {
			var err error
			ssh, err = exec.LookPath(name)
			if err != nil {
				return err
			}
		}
	}
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	p.socks = l.Addr().(*net.TCPAddr).Port
	l.Close()
	_, port, err := net.SplitHostPort(r.sb.ChanAddr())
	if err != nil {
		return err
	}
	null := "/dev/null"
	if runtime.GOOS == "windows" {
		null = "NUL"
	}
	cmd := fmt.Sprintf("~/.local/bin/ra-lab session --pc %s --nonce %s --port %d --version %s", safe(r.o.PC, 80), p.nonce, p.rport, safe(r.o.Version, 80))
	if r.o.Rollback != "" {
		cmd += " --rollback " + safe(r.o.Rollback, 160)
	}
	in, out, err := os.Pipe()
	if err != nil {
		return err
	}
	p.stdin = out
	args := []string{"-T", "-F", null, "-p", port, "-i", key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "UserKnownHostsFile=\"" + strings.ReplaceAll(known, "\\", "/") + "\"", "-o", "GlobalKnownHostsFile=none", "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=" + server.Host, "-o", "ProxyCommand=none", "-o", "ProxyJump=none", "-o", "ConnectionAttempts=1", "-o", "LogLevel=ERROR", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=3", "-R", fmt.Sprintf("127.0.0.1:%d:%s", p.rport, r.o.AgentAddr), "-D", fmt.Sprintf("127.0.0.1:%d", p.socks), server.User + "@127.0.0.1", cmd}
	// OpenSSH's ServerAlive detects a frozen session; no application polling loop.
	p.errors = &probeError{p: p}
	p.proc, err = r.pr.Start(r.ctx, api.ProcSpec{Name: p.name, Path: ssh, Args: args, Stdin: in, Stdout: p, Stderr: p.errors})
	_ = in.Close()
	if err != nil {
		_ = out.Close()
	}
	return err
}
func (r *Rounds) choose(p *probe) {
	p.mu.Lock()
	p.winner = true
	p.state = "winner"
	p.mu.Unlock()
	go func() {
		if err := p.write([]byte("CLAIM\n" + r.agent.Token() + "\n")); err != nil {
			r.stopProbe(p)
		}
	}()
	r.finish(p, false)
}
func (r *Rounds) finish(p *probe, timed bool) {
	p.finished = true
	if r.guard != nil {
		r.guard.Stop()
	}
	p.mu.Lock()
	row := map[string]any{"path": "chan", "node": "chan", "bytes_down": p.rx, "bytes_up": p.upload, "reason": p.reason, "delay_ms": nil, "elapsed_s": time.Since(p.t0).Seconds()}
	if p.winner {
		row["outcome"] = "ok"
		row["down_bps"] = rate(p.t2.Sub(p.t1))
		row["up_bps"] = rate(p.t3.Sub(p.t2))
		row["latency_s"] = p.t1.Sub(p.t0).Seconds()
	} else if timed {
		p.state = "frozen"
		row["outcome"] = "frozen"
		row["rate_bps"] = float64(p.rx) / max(time.Since(p.t0).Seconds(), 1e-6)
	} else {
		row["outcome"] = "failed"
	}
	fatal := p.fatalLocked()
	p.mu.Unlock()
	r.ranking = []map[string]any{row}
	r.save()
	winner := any(nil)
	if p.winner {
		winner = p.path
	}
	r.bus.Publish("round.done", map[string]any{"round": r.rn, "winner": winner, "timer": timed})
	if p.winner {
		rn := r.rn
		go func() {
			ms := r.Uplink.delay(r.ctx, "chan")
			var value any
			if ms != nil {
				value = *ms
			}
			data := map[string]any{"path": "chan", "ms": value, "round": rn}
			r.bus.Publish("path.delay", data)
			r.send(roundEvent{kind: "probe.delay", probe: p, data: data})
		}()
	}
	if !p.winner && !r.stopping && !p.dropped {
		if !fatal {
			r.Uplink.Penalize(p.selected, 120*time.Second)
			r.Uplink.Refresh()
		}
		// v2's repeating backoff/retry timers are replaced by uplink.selected/net.changed.
		// If no alternative succeeds, keep the failed state until the next external event.
	}
}
func (r *Rounds) save() {
	b, err := json.Marshal(map[string]any{"round": r.rn, "ts": time.Now().Format("2006-01-02T15:04:05"), "rows": r.ranking})
	if err != nil {
		return
	}
	path := filepath.Join(r.paths.State, "ranking.json")
	if err = os.MkdirAll(r.paths.State, 0755); err == nil {
		err = os.WriteFile(path+".tmp", b, 0600)
		if err == nil {
			err = os.Rename(path+".tmp", path)
		}
	}
	if err != nil {
		r.info("ranking.save_failed", "error", err)
	}
}
func (r *Rounds) info(ev string, kv ...any) {
	if r.log != nil {
		r.log.With("rounds").Info(ev, kv...)
	}
}
func writePrivate(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	e := f.Close()
	if err != nil {
		return err
	}
	return e
}

var unsafeArg = regexp.MustCompile(`[^A-Za-z0-9._-]`)

func safe(s string, n int) string {
	s = unsafeArg.ReplaceAllString(s, "_")
	if len(s) > n {
		s = s[:n]
	}
	if s == "" {
		s = "x"
	}
	return s
}
func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return ""
	}
	return hex.EncodeToString(b)
}
func rate(d time.Duration) float64 { return probeSize / max(d.Seconds(), 1e-6) }

type probe struct {
	mu                                          sync.Mutex
	writeMu                                     sync.Mutex
	r                                           *Rounds
	proc                                        api.Process
	stdin                                       *os.File
	name, nonce, path, state, reason, sentHex   string
	selected                                    string
	rport, socks, phase, body                   int
	rx, upload                                  int
	buf                                         []byte
	sha                                         hash.Hash
	t0, t1, t2, t3                              time.Time
	stderr                                      []string
	errors                                      *probeError
	winner, finished, dropped, wasUp, agentFail bool
}

func (p *probe) Write(data []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	n := len(data)
	p.rx += n
	if p.state != "run" && p.state != "ok" && p.state != "winner" {
		return n, nil
	}
	for len(data) > 0 {
		if p.phase == 1 {
			take := min(len(data), probeSize-p.body)
			p.sha.Write(data[:take])
			p.body += take
			data = data[take:]
			if p.body == probeSize {
				p.phase = 2
			}
			continue
		}
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			p.buf = append(p.buf, data...)
			if len(p.buf) > 256 {
				p.failLocked("слишком длинная строка протокола")
			}
			break
		}
		p.buf = append(p.buf, data[:i]...)
		data = data[i+1:]
		if len(p.buf) > 256 {
			p.failLocked("слишком длинная строка протокола")
			break
		}
		line := strings.TrimRight(string(p.buf), "\r")
		p.buf = nil
		if err := p.line(line); err != nil {
			p.failLocked(err.Error())
			break
		}
	}
	return n, nil
}
func (p *probe) line(line string) error {
	switch p.phase {
	case 0:
		if line != fmt.Sprintf("RALAB-PROBE1 %s %d", p.nonce, probeSize) {
			return errors.New("неверный заголовок или nonce")
		}
		p.t1 = time.Now()
		p.phase = 1
	case 2:
		if line != "" {
			return errors.New("нет разделителя перед SHA256")
		}
		p.phase = 3
	case 3:
		if line != "SHA256 "+hex.EncodeToString(p.sha.Sum(nil)) {
			return errors.New("не сошлась контрольная сумма вниз")
		}
		p.t2 = time.Now()
		p.phase = 4
		data := make([]byte, probeSize)
		if _, err := rand.Read(data); err != nil {
			return err
		}
		sum := sha256.Sum256(data)
		p.sentHex = hex.EncodeToString(sum[:])
		go func() {
			if err := p.write(data); err != nil {
				p.fail("ошибка отправки пробы")
			} else {
				p.mu.Lock()
				p.upload = probeSize
				p.mu.Unlock()
			}
		}()
	case 4:
		if line != "RALAB-UP1 "+p.nonce+" "+p.sentHex {
			return errors.New("не сошлась контрольная сумма вверх")
		}
		p.upload = probeSize
		p.t3 = time.Now()
		p.phase = 5
		p.state = "ok"
		ev := map[string]any{"name": p.name, "path": p.path, "latency": p.t1.Sub(p.t0).Seconds(), "down_bps": rate(p.t2.Sub(p.t1)), "up_bps": rate(p.t3.Sub(p.t2))}
		p.r.bus.Publish("path.ok", ev)
		p.r.send(roundEvent{kind: "probe.ok", probe: p, data: ev})
	case 5:
		if strings.HasPrefix(line, "RALAB-CHANNEL-UP") && p.winner {
			p.wasUp = true
			version := strings.TrimSpace(strings.TrimPrefix(line, "RALAB-CHANNEL-UP"))
			p.r.send(roundEvent{kind: "probe.up", probe: p, data: map[string]any{"name": p.name, "path": p.r.Uplink.Current(), "rport": p.rport, "socks": p.socks, "via": "chan", "server_version": version}})
		} else if strings.HasPrefix(line, "RALAB-AGENT-FAIL") {
			p.agentFail = true
			p.reason = "агент ПК не ответил серверу"
			p.r.info("agent.fail", "path", p.path)
		}
	}
	return nil
}
func (p *probe) fail(reason string) { p.mu.Lock(); defer p.mu.Unlock(); p.failLocked(reason) }
func (p *probe) failLocked(reason string) {
	if p.state != "run" {
		return
	}
	p.state = "failed"
	p.reason = reason
	ev := map[string]any{"name": p.name, "path": p.path, "reason": reason, "bytes_down": p.rx, "bytes_up": p.upload}
	p.r.bus.Publish("path.failed", ev)
	p.r.send(roundEvent{kind: "probe.failed", probe: p, data: ev})
}
func (p *probe) write(data []byte) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	if p.stdin == nil {
		return io.ErrClosedPipe
	}
	_, err := p.stdin.Write(data)
	return err
}
func (p *probe) close() {
	if p.stdin != nil {
		_ = p.stdin.Close()
	}
}
func (p *probe) exited() bool {
	if p.proc == nil {
		return true
	}
	select {
	case <-p.proc.Done():
		return true
	default:
		return false
	}
}
func (p *probe) fatalLocked() bool {
	tail := strings.Join(p.stderr, " | ")
	return p.agentFail || strings.Contains(tail, "Permission denied") || strings.Contains(tail, "Host key verification failed") || strings.Contains(tail, "remote port forwarding failed")
}
func (p *probe) exitReason(code any) string {
	p.mu.Lock()
	defer p.mu.Unlock()
	tail := strings.Join(p.stderr, " | ")
	for _, k := range []string{"Permission denied", "Host key verification failed", "remote port forwarding failed", "Connection refused", "Connection reset", "Connection closed", "Connection timed out", "Could not resolve"} {
		if strings.Contains(tail, k) {
			return fmt.Sprintf("%s (ssh, код %v)", k, code)
		}
	}
	if len(tail) > 120 {
		tail = tail[len(tail)-120:]
	}
	if tail != "" {
		return tail
	}
	return fmt.Sprintf("ssh вышел, код %v", code)
}

type probeError struct {
	p   *probe
	buf []byte
}

func (w *probeError) Write(data []byte) (int, error) {
	w.buf = append(w.buf, data...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		line := strings.TrimRight(string(w.buf[:i]), "\r")
		w.buf = w.buf[i+1:]
		w.p.mu.Lock()
		if len(line) > 160 {
			line = line[:160]
		}
		w.p.stderr = append(w.p.stderr, line)
		if len(w.p.stderr) > 4 {
			w.p.stderr = w.p.stderr[len(w.p.stderr)-4:]
		}
		w.p.mu.Unlock()
	}
	return len(data), nil
}

func (w *probeError) flush() {
	if len(w.buf) > 0 {
		_, _ = w.Write([]byte("\n"))
	}
}
