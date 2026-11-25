// Package channel implements the newline JSON link to the launcher (v2 link.py).
// The SSH/uplink contracts are separate: this link never opens a network connection.
package channel

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"
	"sync/atomic"

	"remoteagents/internal/agent"
	"remoteagents/internal/api"
	"remoteagents/internal/bus"
)

// Options supplies the context read by v2 Link. Mask must use the journal's shared
// secret masker. In/Out default to stdin/stdout; the caller reserves stdout for
// this protocol and sends other output to stderr.
type Options struct {
	Paths                         api.Paths
	Version, ExeVersion, Rollback string
	Bus                           *bus.Bus
	Log                           api.Logger
	In                            io.ReadCloser
	Out                           io.Writer
	Mask                          func(string) string
	Snapshot                      func() Snapshot
	Report                        func() string
	Update, RollbackEXE           func(send func(map[string]any))
}

type Route struct {
	Path  string
	RPort int
}
type Ranking struct {
	Path, Outcome, Reason string
	DownBPS               int64
}
type LAN struct{ Name, Status, Detail string }

// Snapshot holds the current component status, sampled only on bus events.
type Snapshot struct {
	Channel                *Route
	Round                  int
	Ranking                []Ranking
	Uplink, UplinkOver     string
	UplinkMS               *int
	TUN, VPNMode, VPNState string
	LAN                    []LAN
	DiskRunning            bool
	DiskHome               string
	HappierPort            int
}

type Link struct {
	o                      Options
	mu                     sync.Mutex
	writeMu                sync.Mutex
	start                  sync.Once
	stop                   sync.Once
	color, tip, note, last string
	lines                  []string
	good                   bool
	final                  atomic.Bool
	unsubs                 []func()
}

var topics = []string{"settings.loaded", "settings.failed", "singbox.started", "singbox.failed", "channel.up", "channel.down", "round.done", "lan.result", "path.ok", "path.failed", "agent.ready", "singbox.exited", "uplink.selected", "vpn.state", "disk.state", "control.changed"}

func New(o Options) *Link {
	if o.In == nil {
		o.In = os.Stdin
	}
	if o.Out == nil {
		o.Out = os.Stdout
	}
	l := &Link{o: o, color: "grey", tip: "Запуск", note: "запуск"}
	l.unsubs = append(l.unsubs,
		o.Bus.Subscribe("app.start", func(bus.Event) { _ = l.Start(context.Background()) }),
		o.Bus.Subscribe("app.stop", func(bus.Event) { _ = l.Stop(context.Background()) }),
		o.Bus.Subscribe("link.report_request", func(bus.Event) {
			text := ""
			if o.Report != nil {
				text = o.Report()
			}
			l.Send(map[string]any{"t": "report", "text": clip(o.Mask(text), 64000)})
		}))
	for _, topic := range topics {
		l.unsubs = append(l.unsubs, o.Bus.Subscribe(topic, l.handle))
	}
	return l
}

func (l *Link) Name() string { return "link" }
func (l *Link) Start(context.Context) error {
	l.start.Do(func() { go l.read(); l.Refresh() })
	return nil
}
func (l *Link) Stop(context.Context) error {
	var err error
	l.stop.Do(func() {
		for _, unsub := range l.unsubs {
			unsub()
		}
		err = l.o.In.Close()
	})
	return err
}
func (l *Link) FinalExit() bool { return l.final.Load() }
func (l *Link) Status() map[string]any {
	l.mu.Lock()
	defer l.mu.Unlock()
	return map[string]any{"color": l.color, "tip": l.tip, "lines": append([]string{}, l.lines...)}
}

// Send is the sole protocol writer, also passed to update/rollback operations.
// Mask strings before JSON encoding so quotes in secrets cannot evade masking.
func (l *Link) Send(msg map[string]any) {
	clean := make(map[string]any, len(msg))
	for k, v := range msg {
		switch v := v.(type) {
		case string:
			if msg["t"] == "ui" && k == "url" {
				clean[k] = v
			} else {
				clean[k] = l.o.Mask(v)
			}
		case []string:
			lines := make([]string, len(v))
			for i, s := range v {
				lines[i] = l.o.Mask(s)
			}
			clean[k] = lines
		default:
			clean[k] = v
		}
	}
	l.writeMu.Lock()
	defer l.writeMu.Unlock()
	_ = json.NewEncoder(l.o.Out).Encode(clean)
}

func (l *Link) read() {
	r := bufio.NewReader(l.o.In)
	for {
		raw, err := r.ReadBytes('\n')
		if len(raw) > 0 {
			var msg map[string]any
			if json.Unmarshal(raw, &msg) == nil {
				switch msg["t"] {
				case "exit":
					l.final.Store(truth(msg["final"]))
					l.o.Bus.Publish("app.stop", map[string]any{"reason": "команда exit от EXE"})
				case "report":
					l.o.Bus.Publish("link.report_request", nil)
				case "update":
					if l.o.Update != nil {
						l.o.Update(l.Send)
					}
				case "rollback":
					if l.o.RollbackEXE != nil {
						l.o.RollbackEXE(l.Send)
					}
				case "control":
					if err := agent.SetEnabled(l.o.Paths, truth(msg["enabled"])); err != nil && l.o.Log != nil {
						l.o.Log.Error("link.control", "err", err)
					}
					l.o.Bus.Publish("control.changed", map[string]any{"enabled": agent.Enabled(l.o.Paths)})
					l.Refresh()
				}
			}
		}
		if err != nil {
			break
		}
	}
	l.o.Bus.Publish("app.stop", map[string]any{"reason": "EOF stdin: EXE закрыл связь"})
}

// Python bool() for the JSON values accepted by link.py.
func truth(v any) bool {
	switch v := v.(type) {
	case nil:
		return false
	case bool:
		return v
	case string:
		return v != ""
	case float64:
		return v != 0
	case []any:
		return len(v) != 0
	case map[string]any:
		return len(v) != 0
	}
	return false
}
func clip(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}
func (l *Link) snapshot() Snapshot {
	if l.o.Snapshot != nil {
		return l.o.Snapshot()
	}
	return Snapshot{}
}
func text(v any) string {
	if v == nil {
		return ""
	}
	return fmt.Sprint(v)
}
func count(v any) int {
	switch v := v.(type) {
	case []any:
		return len(v)
	case []string:
		return len(v)
	}
	return 0
}
func (l *Link) set(color, tip, note string) { l.color, l.tip, l.note = color, tip, note }
func (l *Link) handle(ev bus.Event) {
	l.mu.Lock()
	defer l.mu.Unlock()
	s := l.snapshot()
	reason := text(ev.Data["reason"])
	switch ev.Topic {
	case "settings.failed":
		l.set("red", "Настройки: "+reason, "Настройки не прочитаны: "+reason)
	case "settings.loaded":
		l.set("grey", "Запуск sing-box", fmt.Sprintf("Настройки прочитаны: путей %d, сетей %d", count(ev.Data["paths"]), count(ev.Data["lans"])))
	case "singbox.started", "channel.down":
		l.search(s.Round)
	case "round.done":
		if !truth(ev.Data["winner"]) && s.Channel == nil {
			l.search(s.Round)
		}
	case "singbox.failed":
		l.set("red", "sing-box: "+reason, "sing-box не запускается: "+reason)
	case "channel.up":
		path := text(ev.Data["path"])
		l.set("green", "Канал: "+path, "Канал ассистента работает через "+path)
		if !l.good {
			l.good = true
			l.Send(map[string]any{"t": "good", "version": l.o.Version})
		}
	}
	l.refresh(s)
}
func (l *Link) search(round int) {
	note := "Ищу путь"
	if round != 0 {
		note = fmt.Sprintf("Ищу путь к серверу (раунд %d)", round)
	}
	l.set("yellow", "Ищу путь", note)
}
func (l *Link) Refresh() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.refresh(l.snapshot())
}
func (l *Link) refresh(s Snapshot) {
	exe := l.o.ExeVersion
	if exe == "" {
		exe = "-"
	}
	lines := []string{fmt.Sprintf("Код: %s, EXE: %s", l.o.Version, exe)}
	if l.o.Rollback != "" {
		lines = append(lines, "Откат версии: "+l.o.Rollback)
	}
	lines = append(lines, l.note)
	if s.Channel != nil {
		lines = append(lines, fmt.Sprintf("Канал: %s (порт сервера %d)", s.Channel.Path, s.Channel.RPort))
	}
	if s.Uplink != "" {
		ms := "-"
		if s.UplinkMS != nil {
			ms = fmt.Sprintf("%d мс", *s.UplinkMS)
		}
		lines = append(lines, "путь: "+s.Uplink+" "+ms)
	}
	if s.UplinkOver != "" {
		lines = append(lines, s.UplinkOver)
	}
	if s.TUN != "" {
		lines = append(lines, "TUN: "+s.TUN)
	}
	if s.VPNMode != "" {
		lines = append(lines, fmt.Sprintf("VPN (%s): %s", s.VPNMode, s.VPNState))
	}
	for i, r := range s.Ranking {
		if i == 12 {
			break
		}
		detail := clip(r.Reason, 80)
		if r.DownBPS != 0 {
			detail = fmt.Sprintf("%d КиБ/с", r.DownBPS/1024)
		}
		lines = append(lines, fmt.Sprintf("%s: %s %s", r.Path, r.Outcome, detail))
	}
	for i, n := range s.LAN {
		if i == 20 {
			break
		}
		lines = append(lines, fmt.Sprintf("Сеть %s: %s %s", n.Name, n.Status, n.Detail))
	}
	if len(lines) > 50 {
		lines = lines[:50]
	}
	for i, s := range lines {
		lines[i] = clip(l.o.Mask(s), 300)
	}
	l.lines = lines
	msg := map[string]any{"t": "state", "color": l.color, "tip": clip(l.o.Mask(l.tip), 63), "lines": lines, "control": agent.Enabled(l.o.Paths)}
	if s.DiskRunning {
		msg["disk"] = true
		if s.DiskHome != "" {
			msg["diskHome"] = s.DiskHome
		}
	}
	if s.HappierPort != 0 {
		msg["happierPort"] = s.HappierPort
	}
	key, _ := json.Marshal(msg)
	if string(key) != l.last {
		l.last = string(key)
		l.Send(msg)
	}
}
