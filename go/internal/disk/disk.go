// Package disk runs the v2 Syncthing engine and joins configured folders.
package disk

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/bus"
)

// Options supplies existing application services. Exe is the bundled syncthingtray
// binary (v2 bins.find); Installed is the directory with transport state/secrets.
type Options struct {
	Config         *api.Config
	Installed, Exe string
	ExplorerExe    string // Windows helper published from internal/disk/explorer.
	Procs          api.Procs
	Channel        api.Channel
	Forward        api.Forwarder
	Bus            *bus.Bus
	Log            api.Logger
}
type section struct {
	Enabled *bool             `json:"enabled"`
	Home    string            `json:"home"`
	Base    string            `json:"base"`
	Folders []json.RawMessage `json:"folders"`
}
type Disk struct {
	o          Options
	cfg        section
	home, base string
	mu         sync.Mutex
	state      string
	cancel     context.CancelFunc
	done       chan struct{}
	wake       chan string
}

var _ api.Disk = (*Disk)(nil)

func New(o Options) *Disk    { return &Disk{o: o, state: "absent", wake: make(chan string, 16)} }
func (d *Disk) Name() string { return "disk" }
func (d *Disk) Status() map[string]any {
	d.mu.Lock()
	defer d.mu.Unlock()
	return map[string]any{"state": d.state, "home": d.home, "base": d.base}
}
func (d *Disk) set(state string) {
	d.mu.Lock()
	changed := d.state != state
	d.state = state
	d.mu.Unlock()
	if changed {
		d.log("state", "state", state)
		if d.o.Bus != nil {
			d.o.Bus.Publish("disk.state", map[string]any{"state": state})
		}
	}
}
func (d *Disk) log(event string, kv ...any) {
	if d.o.Log != nil {
		d.o.Log.Info("disk."+event, kv...)
	}
}
func (d *Disk) signal(reason string) {
	select {
	case d.wake <- reason:
	default:
	}
}
func (d *Disk) Start(parent context.Context) error {
	// An absent disk section must have no side effects, even with a legacy install.
	if d.o.Config == nil || len(d.o.Config.Disk) == 0 || string(d.o.Config.Disk) == "null" {
		return nil
	}
	if e := json.Unmarshal(d.o.Config.Disk, &d.cfg); e != nil {
		return e
	}
	if d.cfg.Enabled != nil && !*d.cfg.Enabled {
		return nil
	}
	if d.o.Procs == nil || d.o.Channel == nil || d.o.Forward == nil {
		return fmt.Errorf("disk: нужны procs, channel и forward")
	}
	d.home = expand(d.cfg.Home)
	if d.home == "" {
		if os.Getenv("LOCALAPPDATA") == "" {
			return nil
		}
		d.home = defaultHome()
	}
	d.base = expand(d.cfg.Base)
	if d.base == "" {
		d.base = defaultBase()
	}
	if d.o.Exe == "" {
		d.o.Exe = filepath.Join(d.home, "tray", "syncthingtray.exe")
	}
	ctx, cancel := context.WithCancel(parent)
	d.mu.Lock()
	if d.cancel != nil {
		d.mu.Unlock()
		cancel()
		return fmt.Errorf("disk: уже запущен")
	}
	d.cancel = cancel
	d.done = make(chan struct{})
	d.mu.Unlock()
	states, unsubscribe := d.o.Channel.Subscribe()
	var unsub []func()
	if d.o.Bus != nil {
		for _, topic := range []string{"settings.loaded", "net.changed", "app.stop"} {
			topic := topic
			unsub = append(unsub, d.o.Bus.Subscribe(topic, func(bus.Event) {
				if topic == "app.stop" {
					cancel()
				} else {
					d.signal(topic)
				}
			}))
		}
	}
	go func() {
		defer close(d.done)
		defer unsubscribe()
		defer func() {
			for _, u := range unsub {
				u()
			}
		}()
		d.run(ctx, states)
	}()
	return nil
}
func (d *Disk) Stop(ctx context.Context) error {
	d.mu.Lock()
	cancel, done := d.cancel, d.done
	d.mu.Unlock()
	if cancel == nil {
		return nil
	}
	cancel()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func validPort(p int) int {
	if p > 0 && p <= 65535 {
		return p
	}
	return 0
}
func (d *Disk) syncPort() int {
	var state struct {
		Schema    int `json:"schema"`
		Effective struct {
			Sync int `json:"syncPort"`
		} `json:"effective"`
	}
	if readJSON(filepath.Join(d.o.Installed, "state", "transport-ports.json"), &state) && state.Schema == 1 && validPort(state.Effective.Sync) != 0 {
		return state.Effective.Sync
	}
	var cfg struct {
		Transport struct {
			Sync int `json:"syncPort"`
		} `json:"transport"`
	}
	_ = json.Unmarshal(d.o.Config.Raw, &cfg)
	if validPort(cfg.Transport.Sync) != 0 {
		return cfg.Transport.Sync
	}
	return 22001
}
func (d *Disk) serverInfo() server {
	var s server
	readJSON(filepath.Join(d.home, "server.json"), &s)
	var cfg struct {
		Transport struct {
			Path string `json:"channelPath"`
		} `json:"transport"`
	}
	_ = json.Unmarshal(d.o.Config.Raw, &cfg)
	files, _ := filepath.Glob(filepath.Join(d.o.Installed, "secrets", "channel-disk-*.json"))
	sort.Slice(files, func(i, j int) bool {
		a, e := os.Stat(files[i])
		b, f := os.Stat(files[j])
		return e == nil && f == nil && a.ModTime().After(b.ModTime())
	})
	if cfg.Transport.Path != "" {
		files = append([]string{cfg.Transport.Path}, files...)
	}
	for _, path := range files {
		var channel struct {
			Inbounds []struct {
				Tag  string `json:"tag"`
				Port int    `json:"override_port"`
			} `json:"inbounds"`
		}
		if readJSON(path, &channel) {
			for _, i := range channel.Inbounds {
				if i.Tag == "sync" && validPort(i.Port) != 0 {
					s.Listen = i.Port
					return s
				}
			}
		}
	}
	s.Listen = validPort(s.Listen)
	return s
}
func listening(port int) bool {
	c, e := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 500*time.Millisecond)
	if e != nil {
		return false
	}
	_ = c.Close()
	return true
}

type eventResult struct {
	events []event
	err    error
}

func (d *Disk) run(ctx context.Context, states <-chan api.ChannelState) {
	var helper *explorer
	helperTried := false
	var process api.Process
	var exited <-chan struct{}
	var r *rest
	var restCancel context.CancelFunc
	results := make(chan eventResult, 1)
	var eventC <-chan eventResult
	var since int64
	var retry *time.Timer
	var retryC <-chan time.Time
	defer func() {
		if retry != nil {
			retry.Stop()
		}
		if restCancel != nil {
			restCancel()
		}
		if r != nil {
			r.client.CloseIdleConnections()
		}
		helper.stop()
		if process != nil {
			stop, c := context.WithTimeout(context.Background(), 6*time.Second)
			defer c()
			_ = process.Stop(stop)
		}
		_ = d.o.Forward.Unexpose("disk")
		d.set("absent")
	}()
	schedule := func(delay time.Duration) {
		if retry != nil {
			retry.Stop()
		}
		retry = time.NewTimer(delay)
		retryC = retry.C
	}
	up := d.o.Channel.State().State == "up"
	fails, joinFails := 0, 0
	var started time.Time
	var next, joinNext, apiNext time.Time
	fwdPort, fwdServer := 0, 0
	ready := false
	poll := func() {
		if r == nil || eventC != nil {
			return
		}
		ec, cancel := context.WithCancel(ctx)
		restCancel = cancel
		current := r
		cursor := since
		eventC = results
		go func() {
			events, e := current.events(ec, cursor)
			select {
			case results <- eventResult{events, e}:
			case <-ctx.Done():
			}
		}()
	}
	for {
		if ctx.Err() != nil {
			return
		}
		now := time.Now()
		if process == nil {
			if !exists(d.o.Exe) {
				d.set("absent")
			} else {
				state := filepath.Join(d.home, "state")
				var p progress
				readJSON(filepath.Join(d.home, "join.json"), &p)
				needJoin := !exists(filepath.Join(state, "config.xml")) || p.Stage == "identity" || p.Stage == "server"
				if needJoin {
					d.set("absent")
					if up && !now.Before(joinNext) {
						e := d.join(ctx)
						if e != nil {
							joinFails++
							delay := 60 * time.Second
							if joinFails >= 3 {
								delay = 300 * time.Second
							}
							joinNext = time.Now().Add(delay)
							schedule(delay)
							d.log("join-failed", "fails", joinFails)
						} else {
							joinFails = 0
							joinNext = time.Time{}
							d.signal("joined")
						}
					}
				} else {
					s := d.serverInfo()
					port := d.syncPort()
					switch {
					case s.Listen == 0:
						d.set("absent")
					case fails >= 5:
						d.set("error")
					case !up || now.Before(next):
						d.set("wait")
					default:
						busy := fwdPort != port && listening(port) || d.foreignRunning(ctx)
						if busy {
							d.set("program")
							// §5б исключение: старая Программа не сообщает об освобождении
							// порта/мьютекса в нашу шину; проверка только пока уступаем ей.
							schedule(60 * time.Second)
						} else {
							if fwdPort != port || fwdServer != s.Listen {
								if fwdPort != 0 {
									_ = d.o.Forward.Unexpose("disk")
									fwdPort, fwdServer = 0, 0
								}
								exposed, e := d.o.Forward.Expose("disk", s.Listen, port)
								if e != nil || exposed.PCPort != port {
									_ = d.o.Forward.Unexpose("disk")
									d.set("program")
									schedule(60 * time.Second)
									break
								}
								fwdPort, fwdServer = port, s.Listen
							}
							unlock, e := engineLock(d.home)
							if e != nil {
								d.set("wait")
								schedule(60 * time.Second)
								break
							}
							output := &lineWriter{d: d}
							env := append(os.Environ(), "STMONITORED=yes")
							process, e = d.o.Procs.Start(ctx, api.ProcSpec{Name: "syncthing", Path: d.o.Exe, Args: []string{"syncthing", "serve", "--home", state, "--no-browser", "--no-restart"}, Env: env, Stdout: output, Stderr: output})
							unlock()
							if e != nil {
								fails++
								delay := backoff(fails)
								next = time.Now().Add(delay)
								schedule(delay)
								if fails >= 5 {
									d.set("error")
								} else {
									d.set("wait")
								}
								d.log("failed", "fails", fails)
							} else {
								started = time.Now()
								exited = process.Done()
								ready = false
								apiNext = time.Time{}
								since = 0
								d.set("running")
								// One startup deadline, replacing v2 wait_api's forty sleeps.
								schedule(10 * time.Second)
							}
						}
					}
				}
			}
		} else if ready && r == nil && !now.Before(apiNext) {
			var e error
			r, e = d.localAPI()
			if e != nil {
				d.log("api-unavailable")
				apiNext = time.Now().Add(10 * time.Second)
				schedule(10 * time.Second)
			} else {
				s := d.serverInfo()
				if e = d.finish(ctx, r, s); e != nil {
					d.log("join-failed")
					schedule(60 * time.Second)
				}
				if !helperTried {
					helper = d.startExplorer(ctx)
					helperTried = true
				}
				helper.wake()
				poll()
			}
		}
		select {
		case <-ctx.Done():
			return
		case state, ok := <-states:
			if !ok {
				states = nil
				up = false
			} else {
				up = state.State == "up"
			}
		case reason := <-d.wake:
			if reason == "net.changed" {
				fails = 0
				next = time.Time{}
			}
			if reason == "ready" {
				ready = true
			}
		case <-retryC:
			retryC = nil
			if process != nil {
				ready = true
			}
			if process != nil && r != nil {
				if e := d.finish(ctx, r, d.serverInfo()); e != nil {
					d.log("join-failed")
					schedule(60 * time.Second)
				}
				poll()
			}
		case result := <-eventC:
			eventC = nil
			if result.err != nil {
				if r != nil {
					r.client.CloseIdleConnections()
				}
				r = nil
				d.log("api-unavailable")
				apiNext = time.Now().Add(10 * time.Second)
				schedule(10 * time.Second)
			} else {
				for _, ev := range result.events {
					if ev.ID > since {
						since = ev.ID
					}
				}
				if len(result.events) > 0 {
					if e := d.finish(ctx, r, d.serverInfo()); e != nil {
						d.log("join-failed")
						schedule(60 * time.Second)
					}
				}
				helper.wake()
				poll()
			}
		case <-exited:
			helper.stop()
			helper = nil
			helperTried = false
			exited = nil
			process = nil
			ready = false
			if restCancel != nil {
				restCancel()
			}
			if eventC != nil {
				select {
				case <-results:
				case <-ctx.Done():
					return
				}
				eventC = nil
			}
			if r != nil {
				r.client.CloseIdleConnections()
				r = nil
			}
			if time.Since(started) > 120*time.Second {
				fails = 0
			}
			// Ownership is checked after our process exited, never against a stale probe.
			if d.foreignRunning(ctx) {
				d.set("program")
				schedule(60 * time.Second)
			} else {
				fails++
				delay := backoff(fails)
				next = time.Now().Add(delay)
				schedule(delay)
				d.log("failed", "fails", fails)
			}
		}
	}
}
func backoff(fails int) time.Duration {
	if fails > 4 {
		return 300 * time.Second
	}
	return time.Duration(30*(1<<max(0, fails-1))) * time.Second
}

var warningPattern = regexp.MustCompile(`\b(WARN|WARNING|ERR|ERROR)\b`)
var pathPattern = regexp.MustCompile(`[A-Za-z]:[\\/][^\s"']*|(?:\\\\|/)[^\s"']+|"[^"]*"|'[^']*'`)

type lineWriter struct {
	mu      sync.Mutex
	d       *Disk
	pending string
	last    time.Time
}

var _ io.Writer = (*lineWriter)(nil)

func (w *lineWriter) Write(b []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.pending += string(b)
	for {
		line, rest, ok := strings.Cut(w.pending, "\n")
		if !ok {
			break
		}
		w.pending = rest
		if strings.Contains(line, "GUI and API listening") || strings.Contains(line, "Access the GUI via") {
			w.d.signal("ready")
		}
		if warningPattern.MatchString(line) && time.Since(w.last) > 2*time.Second {
			w.last = time.Now()
			safe := []rune(pathPattern.ReplaceAllString(line, "<..>"))
			if len(safe) > 120 {
				safe = safe[:120]
			}
			w.d.log("syncthing", "line", string(safe))
		}
	}
	return len(b), nil
}
