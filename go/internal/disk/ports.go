package disk

import (
	"context"
	"io"
	"net"
	"strconv"
	"sync"

	"remoteagents/internal/api"
)

// portForward — 127.0.0.1:local → server 127.0.0.1:srv через канал (DialContext канала).
type portForward struct {
	ln     net.Listener
	ch     api.Channel
	srv    int
	local  int
	mu     sync.Mutex
	conns  map[net.Conn]struct{}
	closed bool
	wg     sync.WaitGroup
}

func openForward(ch api.Channel, local, srv int) (*portForward, error) {
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(local)))
	if err != nil {
		return nil, err
	}
	f := &portForward{ln: ln, ch: ch, srv: srv, local: local, conns: map[net.Conn]struct{}{}}
	f.wg.Add(1)
	go f.accept()
	return f, nil
}

func (f *portForward) track(c net.Conn) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return false
	}
	f.conns[c] = struct{}{}
	return true
}

func (f *portForward) untrack(c net.Conn) {
	f.mu.Lock()
	delete(f.conns, c)
	f.mu.Unlock()
}

func (f *portForward) accept() {
	defer f.wg.Done()
	for {
		c, err := f.ln.Accept()
		if err != nil {
			return
		}
		f.wg.Add(1)
		go f.serve(c)
	}
}

func (f *portForward) serve(c net.Conn) {
	defer f.wg.Done()
	defer c.Close()
	if !f.track(c) {
		return
	}
	defer f.untrack(c)
	if f.ch.State().State != "up" {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	up, err := f.ch.DialContext(ctx, "tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(f.srv)))
	if err != nil {
		return
	}
	defer up.Close()
	if !f.track(up) {
		return
	}
	defer f.untrack(up)
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		_, _ = io.Copy(dst, src)
		done <- struct{}{}
	}
	go cp(up, c)
	go cp(c, up)
	<-done // одна сторона закрылась — закрываем обе (defer), вторая копия выйдет сама
}

// dropConns — оборвать открытые соединения (канал упал/пересобран); слушатель остаётся.
func (f *portForward) dropConns() {
	f.mu.Lock()
	for c := range f.conns {
		_ = c.Close()
	}
	f.mu.Unlock()
}

func (f *portForward) close() {
	f.mu.Lock()
	f.closed = true
	f.mu.Unlock()
	_ = f.ln.Close()
	f.dropConns()
	f.wg.Wait()
}
