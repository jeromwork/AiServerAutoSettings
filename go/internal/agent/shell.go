package agent

import (
	"context"
	"encoding/base64"
	"errors"
	"runtime"
	"strconv"
	"sync"
	"time"
	"unicode/utf16"

	"remoteagents/internal/api"
)

const (
	outMax  = 1 << 20 // буфер вывода на поток
	execMax = 64      // процессов в списке
)

// ErrTooMany — в списке 64 процесса и ни один не завершён.
var ErrTooMany = errors.New("shell: too-many")

// NewShell — запуск команд поверх procs (v2 agent.py Exec/build_command). Платформенная заглушка api.Shell может вернуть его.
func NewShell(log api.Logger, pr api.Procs) api.Shell {
	return &shell{log: log, pr: pr, m: map[string]*execProc{}}
}

type shell struct {
	log api.Logger
	pr  api.Procs
	mu  sync.Mutex
	seq int
	m   map[string]*execProc
}

type execProc struct {
	id, cmd string
	proc    api.Process
	mu      sync.Mutex
	buf     [2][]byte
	base    [2]int // сколько байт отброшено спереди
	trunc   bool
	wake    chan struct{} // закрывается и заменяется при новых данных
}

type sink struct {
	e *execProc
	i int
}

func (s sink) Write(p []byte) (int, error) {
	e := s.e
	e.mu.Lock()
	b := append(e.buf[s.i], p...)
	if len(b) > outMax {
		cut := len(b) - outMax
		b = append([]byte(nil), b[cut:]...)
		e.base[s.i] += cut
		e.trunc = true
	}
	e.buf[s.i] = b
	close(e.wake)
	e.wake = make(chan struct{})
	e.mu.Unlock()
	return len(p), nil
}

func isCmd(shell string) bool { return runtime.GOOS == "windows" && shell == "cmd" }

func defaultShell() string {
	if runtime.GOOS == "windows" {
		return "powershell"
	}
	return "/bin/sh"
}

// buildCommand: Windows cmd — одна командная строка; powershell — -EncodedCommand (UTF-16LE base64); иначе /bin/sh -c.
func buildCommand(cmd, shell string) (path string, args []string, line string) {
	if runtime.GOOS != "windows" {
		return "/bin/sh", []string{"-c", cmd}, ""
	}
	if isCmd(shell) {
		return "cmd.exe", nil, `cmd.exe /d /s /c "chcp 65001>nul & ` + cmd + `"`
	}
	u := utf16.Encode([]rune("[Console]::OutputEncoding=[Text.Encoding]::UTF8\n" + cmd))
	raw := make([]byte, 0, len(u)*2)
	for _, c := range u {
		raw = append(raw, byte(c), byte(c>>8))
	}
	return "powershell.exe", []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", base64.StdEncoding.EncodeToString(raw)}, ""
}

func (s *shell) Start(ctx context.Context, r api.ExecReq) (api.ExecProc, error) {
	s.mu.Lock()
	if len(s.m) >= execMax {
		old := ""
		for k, v := range s.m {
			if v.Exited() {
				old = k
				break
			}
		}
		if old == "" {
			s.mu.Unlock()
			return nil, ErrTooMany
		}
		delete(s.m, old)
	}
	s.seq++
	e := &execProc{id: strconv.Itoa(s.seq), cmd: r.Cmd, wake: make(chan struct{})}
	s.mu.Unlock()
	path, args, line := buildCommand(r.Cmd, r.Shell)
	p, err := s.pr.Start(context.WithoutCancel(ctx), api.ProcSpec{Name: "exec:" + e.id, Path: path, Args: args, CmdLine: line, Dir: r.Cwd,
		Stdout: sink{e, 0}, Stderr: sink{e, 1}})
	if err != nil {
		return nil, err
	}
	e.proc = p
	s.mu.Lock()
	s.m[e.id] = e
	s.mu.Unlock()
	return e, nil
}

func (s *shell) Get(id string) (api.ExecProc, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	e, ok := s.m[id]
	if !ok {
		return nil, false
	}
	return e, true
}

func (s *shell) List() []api.ExecProc {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*execProc, 0, len(s.m))
	for _, e := range s.m {
		out = append(out, e)
	}
	// по номеру запуска
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && num(out[j].id) < num(out[j-1].id); j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	res := make([]api.ExecProc, len(out))
	for i, e := range out {
		res[i] = e
	}
	return res
}

func num(id string) int { n, _ := strconv.Atoi(id); return n }

func (s *shell) KillAll() error { return s.pr.KillAll(context.Background()) }

func (e *execProc) ID() string  { return e.id }
func (e *execProc) Cmd() string { return e.cmd }

func idx(stream string) int {
	if stream == "err" {
		return 1
	}
	return 0
}

func (e *execProc) Read(stream string, off int) api.Chunk {
	i := idx(stream)
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.readLocked(i, off)
}

func (e *execProc) readLocked(i, off int) api.Chunk {
	base := e.base[i]
	if off < base {
		off = base
	}
	data := append([]byte(nil), e.buf[i][off-base:]...)
	return api.Chunk{Data: data, NextOff: off + len(data), Base: base}
}

func (e *execProc) end(i int) int { return e.base[i] + len(e.buf[i]) }

// WaitNew ждёт выхода процесса или новых байт за смещениями (событие, не опрос); max 0 — без предела.
func (e *execProc) WaitNew(ctx context.Context, outOff, errOff int, max time.Duration) {
	var timeout <-chan time.Time
	if max > 0 {
		t := time.NewTimer(max) // таймаут одного ожидания
		defer t.Stop()
		timeout = t.C
	}
	for {
		e.mu.Lock()
		have := outOff < e.end(0) || errOff < e.end(1)
		w := e.wake
		e.mu.Unlock()
		if have || e.Exited() {
			return
		}
		select {
		case <-w:
		case <-e.proc.Done():
		case <-ctx.Done():
			return
		case <-timeout:
			return
		}
	}
}

func (e *execProc) Exited() bool {
	select {
	case <-e.proc.Done():
		return true
	default:
		return false
	}
}

func (e *execProc) Drained(outOff, errOff int) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.Exited() && outOff >= e.end(0) && errOff >= e.end(1)
}

func (e *execProc) Code() int {
	if !e.Exited() {
		return -1
	}
	return e.proc.ExitCode()
}

func (e *execProc) Truncated() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.trunc
}

func (e *execProc) Kill() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return e.proc.Stop(ctx)
}
