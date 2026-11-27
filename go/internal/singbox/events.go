package singbox

import (
	"context"
	"io"
	"strings"
	"sync"

	"remoteagents/internal/api"
)

// Классы событий из журнала канального sing-box (сами строки наружу не уходят).
const (
	EvNetworkChanged = "network-changed"
	EvOutboundError  = "outbound-error"
)

// classify: строка журнала sing-box -> класс события ("" — неинтересно).
func classify(line string) string {
	l := strings.ToLower(line)
	switch {
	case strings.Contains(l, "network changed"), strings.Contains(l, "updated default interface"):
		return EvNetworkChanged
	case strings.Contains(l, "error") && (strings.Contains(l, "outbound/") || strings.Contains(l, "in-chan")):
		return EvOutboundError
	}
	return ""
}

// tap — построчный читатель потока sing-box; каждую интересную строку превращает в вызов on(класс).
type tap struct {
	mu  sync.Mutex
	buf []byte
	on  func(kind string)
}

func (t *tap) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	n := len(p)
	for len(p) > 0 {
		i := strings.IndexByte(string(p), '\n')
		part := p
		if i >= 0 {
			part = p[:i]
		}
		if len(t.buf)+len(part) <= 16<<10 {
			t.buf = append(t.buf, part...)
		}
		if i < 0 {
			break
		}
		if k := classify(string(t.buf)); k != "" {
			t.on(k)
		}
		t.buf = t.buf[:0]
		p = p[i+1:]
	}
	return n, nil
}

// outWriters — вывод процесса: в журнал (как раньше) и, для канального sing-box, в читатель событий.
func (s *box) outWriters() (io.Writer, io.Writer) {
	if s.isVPN() || s.o.OnEvent == nil {
		return nil, nil
	}
	mk := func() io.Writer {
		return io.MultiWriter(s.log.Writer(api.StreamSB, s.Name()), &tap{on: s.o.OnEvent})
	}
	return mk(), mk()
}

// track учитывает живой процесс; другие ещё живые процессы этого sing-box — утечка: событие channel.leak и уборка.
func (s *box) track(p api.Process) {
	s.pmu.Lock()
	if s.procs == nil {
		s.procs = map[api.Process]struct{}{}
	}
	var stale []api.Process
	for o := range s.procs {
		select {
		case <-o.Done():
		default:
			stale = append(stale, o)
		}
	}
	s.procs[p] = struct{}{}
	s.pmu.Unlock()
	go func() {
		<-p.Done()
		s.pmu.Lock()
		delete(s.procs, p)
		s.pmu.Unlock()
	}()
	if len(stale) > 0 {
		s.log.Warn("channel.leak", "kind", "singbox-proc", "name", s.Name(), "stale", len(stale))
		for _, o := range stale {
			go func() { _ = o.Stop(context.Background()) }()
		}
	}
}

// Procs — число живых процессов этого sing-box (норма 1, 0 — не запущен).
func (s *box) Procs() int {
	s.pmu.Lock()
	defer s.pmu.Unlock()
	return len(s.procs)
}
