// Package supervise mirrors the v2 EXE supervisor (LabMain.cs Supervisor + CodeSlots.cs): it starts the core,
// restarts it by its exit code, keeps version slots and rolls back a version that never proved itself.
package supervise

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/bus"
	"remoteagents/internal/journal"
	"remoteagents/internal/procs"
)

const (
	finalExitGrace = 80 * time.Second // v2 FinalExitGraceSeconds: TUN stop + cleanup
	maxLine        = 200000
	maxQueued      = 1000
)

// Options supplies release trust and the tray event bridge.
type Options struct {
	Bus     *bus.Bus
	Signers []string
	Repo    string
}

// Run is the whole life of the supervisor. args are the command line after "supervise". log and pr may be nil.
func Run(ctx context.Context, p api.Paths, log api.Logger, pr api.Procs, self string, mode api.Mode, args []string, options ...Options) int {
	var o Options
	if len(options) > 0 {
		o = options[0]
	}
	_ = mode // already inside args: the core gets the same flags
	for _, d := range []string{p.State, p.Versions, p.Logs, p.Tmp} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return 1
		}
	}
	if log == nil {
		if j, err := journal.New(p, api.StreamSup); err == nil {
			defer func() { _ = j.Close() }()
			log = j
		} else {
			log = journal.Boot(p.Home)
		}
	}
	if pr == nil {
		pr = procs.New(log, nil)
	}
	release, ok, err := lockFile(filepath.Join(p.State, api.LockRun))
	if err != nil {
		log.Error("lock", "err", err.Error())
		return 1
	}
	if !ok {
		log.Warn("already-running")
		return api.SupExitRunning
	}
	defer release()
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()

	if exe, err := os.Executable(); err == nil {
		self = exe
	}
	embedded, err := embeddedName(self)
	if err != nil {
		log.Error("embedded", "err", err.Error())
		return 1
	}
	coreArgs, reset := coreArgs(args)
	s := loadSlots(p, self, embedded, reset, log)
	for {
		r := runCore(ctx, log, pr, s, coreArgs, o)
		if r.exiting || (r.code == api.ExitOK && r.exitMsg) {
			log.Info("exit", "why", "ядро завершилось по просьбе владельца")
			return api.SupExitDone
		}
		act := s.onExit(r.code, r.fuse, r.ran.Seconds(), r.good, log)
		log.Info("decision", "restart", act == actRestart, "why", s.reason)
		if act == actStop {
			// Keep the v2 stopped tray available for Exit or Rollback, without restarting the core.
			_ = pr.KillAll(context.Background())
			if o.Bus == nil {
				return api.SupExitDone
			}
			commands := make(chan string, 1)
			unsub := o.Bus.Subscribe("supervisor.command", func(ev bus.Event) {
				kind, _ := ev.Data["t"].(string)
				if kind == "exit" || kind == "rollback" {
					select {
					case commands <- kind:
					default:
					}
				}
			})
			o.Bus.Publish("supervisor.message", map[string]any{"t": "core", "running": false, "rollback": s.Previous != "" || s.LastGood != ""})
			restart := false
			for !restart {
				select {
				case <-ctx.Done():
					unsub()
					return api.SupExitDone
				case kind := <-commands:
					if kind == "exit" {
						unsub()
						return api.SupExitDone
					}
					previous := s.Previous
					if previous == "" || previous == s.Current {
						previous = s.LastGood
					}
					if previous != "" && previous != s.Current && s.exists(previous) {
						s.Current = previous
						s.FailsGood = 0
						s.MemRestarts = 0
						s.save(log)
						restart = true
					}
				}
			}
			unsub()
		}
	}
}

// embeddedName is v2 "emb-<hash of the embedded code>": here the hash of the supervisor's own file.
func embeddedName(self string) (string, error) {
	f, err := os.Open(self)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return "emb-" + hex.EncodeToString(h.Sum(nil)[:6]), nil
}

// coreArgs: the core command line is "run" + the supervisor flags without the supervisor-only --reset and --rollback-reason.
func coreArgs(args []string) (out []string, reset bool) {
	out = []string{"run"}
	for i := 0; i < len(args); i++ {
		name := strings.TrimLeft(args[i], "-")
		switch {
		case name == "reset":
			reset = true
		case name == "rollback-reason":
			i++
		case strings.HasPrefix(name, "rollback-reason="):
		default:
			out = append(out, args[i])
		}
	}
	return out, reset
}

type result struct {
	code       int
	fuse, good bool
	exitMsg    bool // the core said {"t":"exit"} before leaving
	exiting    bool // we were asked to stop (signal)
	ran        time.Duration
}

type msg struct{ t string }

// lineWriter splits core stdout into JSON lines (v2 ReadOut/OnLine); a full queue drops the line.
type lineWriter struct {
	buf  []byte
	skip bool
	out  chan msg
	log  api.Logger
	bus  *bus.Bus
}

func (w *lineWriter) Write(b []byte) (int, error) {
	for _, c := range b {
		switch {
		case c == '\n':
			if !w.skip && len(w.buf) > 0 {
				w.line(w.buf)
			}
			w.buf, w.skip = w.buf[:0], false
		case c == '\r':
		case len(w.buf) < maxLine:
			w.buf = append(w.buf, c)
		default:
			w.skip = true
		}
	}
	return len(b), nil
}

func (w *lineWriter) line(b []byte) {
	var m struct {
		T string `json:"t"`
	}
	if json.Unmarshal(b, &m) != nil || m.T == "" {
		w.log.Warn("core.notjson", "len", len(b)) // content is not logged: it may hold secrets
		return
	}
	var data map[string]any
	if json.Unmarshal(b, &data) == nil {
		if m.T == "ui" {
			if value, ok := data["url"].(string); ok {
				if u, err := url.Parse(value); err == nil {
					w.log.Secret(u.Query().Get("t"))
				}
			}
		}
		w.bus.Publish("supervisor.message", data)
		if m.T == api.MsgConfigOK && data["channel"] == false {
			m.T = "config-only"
		}
	}
	select {
	case w.out <- msg{m.T}:
	default:
		w.log.Warn("core.queue.full")
	}
}

func runCore(ctx context.Context, log api.Logger, pr api.Procs, s *slots, args []string, options ...Options) result {
	var o Options
	if len(options) > 0 {
		o = options[0]
	}
	var res result
	argv := append([]string(nil), args...)
	argv = append(argv, "--launcher", s.self)
	if len(o.Signers) > 0 {
		argv = append(argv, "--update-signers", strings.Join(o.Signers, "\n"))
	}
	if o.Repo != "" {
		argv = append(argv, "--release-repo", o.Repo)
	}
	if s.RollbackReason != "" {
		argv = append(argv, "--rollback-reason", asciiClean(s.RollbackReason, 160))
	}
	stdinR, stdinW, err := os.Pipe() // stdin of the core; closing our end = EOF = "exit"
	if err != nil {
		res.code = -2
		return res
	}
	defer func() { _ = stdinW.Close() }()
	msgs := make(chan msg, maxQueued)
	var inputMu sync.Mutex
	send := func(data map[string]any) {
		inputMu.Lock()
		defer inputMu.Unlock()
		_ = json.NewEncoder(stdinW).Encode(data)
	}
	if o.Bus != nil {
		unsub := o.Bus.Subscribe("supervisor.command", func(ev bus.Event) { send(ev.Data) })
		defer unsub()
	}
	log.Info("start", "version", s.Current, "unverified", s.unverified(), "rollback", s.RollbackReason)
	proc, err := pr.Start(ctx, api.ProcSpec{Name: "core", Path: s.exePath(s.Current), Args: argv, Dir: s.home,
		Stream: api.StreamCore, Stdin: stdinR, Stdout: &lineWriter{out: msgs, log: log, bus: o.Bus}})
	_ = stdinR.Close() // the child owns its copy
	if err != nil {
		log.Error("start.failed", "err", err.Error())
		res.code = -2
		return res
	}
	started := time.Now()
	if o.Bus != nil {
		o.Bus.Publish("supervisor.message", map[string]any{"t": "core", "running": true, "rollback": s.Previous != "" || (s.LastGood != "" && s.LastGood != s.Current)})
		defer o.Bus.Publish("supervisor.message", map[string]any{"t": "core", "running": false})
	}

	// Silence timer (v2 "таймер В"): a version that was never proven must say good in time. §5б exception: no event
	// exists for a hung new version, and the owner would be left without a link. Only a timeout of one action; success is never declared by it.
	var fuse *time.Timer
	var fuseC <-chan time.Time
	arm := func() {
		if fuse != nil {
			fuse.Stop()
			fuse, fuseC = nil, nil
		}
		if s.unverified() && !res.good {
			fuse = time.NewTimer(api.SilenceUnverifiedSec * time.Second)
			fuseC = fuse.C
		}
	}
	disarm := func() {
		if fuse != nil {
			fuse.Stop()
			fuse, fuseC = nil, nil
		}
	}
	defer disarm()
	arm()
	noConfig := false
	var graceC <-chan time.Time // §5б exception: grace for a soft exit, a timeout of one action
	ctxDone := ctx.Done()

	handle := func(m msg) {
		switch m.t {
		case api.MsgGood:
			res.good = true
			disarm()
			s.markGood(log)
			log.Info("good", "version", s.Current)
		case api.MsgExit:
			res.exitMsg = true
		case "config-only":
			disarm() // No SSH is configured (e.g. VPN-only); never claim channel verification.
		case api.MsgNoConfig:
			noConfig = true
			disarm()
		case api.MsgConfigOK:
			if noConfig {
				noConfig = false
				arm()
			}
		}
	}
	for {
		select {
		case m := <-msgs:
			handle(m)
		case <-fuseC:
			log.Warn("fuse", "version", s.Current, "why", "не подняла канал, гашу ядро")
			res.fuse = true
			fuseC = nil
			go func() { _ = proc.Stop(context.Background()) }()
		case <-ctxDone:
			ctxDone = nil
			res.exiting = true
			disarm()
			send(map[string]any{"t": "exit", "final": true})
			grace := time.NewTimer(finalExitGrace)
			defer grace.Stop()
			graceC = grace.C
		case <-graceC:
			log.Warn("grace", "why", "ядро не вышло за срок, гашу")
			graceC = nil
			go func() { _ = proc.Stop(context.Background()) }()
		case <-proc.Done():
			for { // lines written before the exit
				select {
				case m := <-msgs:
					handle(m)
					continue
				default:
				}
				break
			}
			res.code, res.ran = proc.ExitCode(), time.Since(started)
			log.Info("exited", "code", res.code, "sec", int(res.ran.Seconds()), "fuse", res.fuse, "good", res.good)
			return res
		}
	}
}

func asciiClean(s string, max int) string {
	var b bytes.Buffer
	for _, r := range s {
		if b.Len() >= max {
			break
		}
		if r >= 0x20 && r < 0x7f {
			b.WriteRune(r)
		} else {
			b.WriteByte('?')
		}
	}
	return b.String()
}
