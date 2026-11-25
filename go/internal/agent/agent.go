// Package agent implements the authenticated HTTP endpoint carried by the SSH channel.
package agent

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/api"
)

const (
	bodyMax = 8 << 20
	devMax  = 100 << 20
	concMax = 4
)

type Agent struct {
	d        api.AgentDeps
	token    string
	instance string
	ctx      context.Context
	cancel   context.CancelFunc
	sem      chan struct{}
	mu       sync.Mutex
	closed   bool
	servers  map[*http.Server]struct{}
	wg       sync.WaitGroup
	requests sync.WaitGroup
	execMu   sync.Mutex
	execs    map[string]execution
	writeMu  sync.Mutex
	parts    map[string]struct{}
	started  time.Time
	port     int
}

type execution struct {
	id   string
	cmd  string
	proc api.ExecProc
}

var _ api.AgentHost = (*Agent)(nil)

func New(d api.AgentDeps) (*Agent, error) {
	if d.Log == nil || d.Act == nil || d.Shell == nil || d.Control == nil || d.Paths.Home == "" {
		return nil, errors.New("agent: dependencies: log, actions, shell, control and home required")
	}
	var secret [48]byte
	if _, err := rand.Read(secret[:]); err != nil {
		return nil, fmt.Errorf("agent: random: %w", err)
	}
	token := base64.RawURLEncoding.EncodeToString(secret[:32])
	d.Log.Secret(token)
	if d.MaxBody <= 0 || d.MaxBody > bodyMax {
		d.MaxBody = bodyMax
	}
	if d.MaxDev <= 0 || d.MaxDev > devMax {
		d.MaxDev = devMax
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Agent{
		d:        d,
		token:    token,
		instance: hex.EncodeToString(secret[32:]),
		ctx:      ctx,
		cancel:   cancel,
		sem:      make(chan struct{}, concMax),
		servers:  make(map[*http.Server]struct{}),
		execs:    make(map[string]execution),
		parts:    make(map[string]struct{}),
		started:  time.Now(),
	}, nil
}

func (a *Agent) Token() string { return a.token }

// Serve starts serving before returning. The channel owns l and may close it on reconnect.
func (a *Agent) Serve(l net.Listener) {
	if l == nil {
		return
	}
	srv := &http.Server{
		Handler:           a,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      35 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    16 << 10,
		BaseContext: func(net.Listener) context.Context {
			return a.ctx
		},
	}
	srv.SetKeepAlivesEnabled(false)

	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		_ = l.Close()
		return
	}
	a.servers[srv] = struct{}{}
	if addr, ok := l.Addr().(*net.TCPAddr); ok {
		a.port = addr.Port
	}
	a.wg.Add(1)
	a.mu.Unlock()

	go func() {
		defer a.wg.Done()
		err := srv.Serve(l)
		_ = srv.Close()
		a.mu.Lock()
		delete(a.servers, srv)
		a.mu.Unlock()
		if err != nil && !errors.Is(err, http.ErrServerClosed) && !errors.Is(err, net.ErrClosed) {
			a.d.Log.Warn("serve", "error", err.Error())
		}
	}()
}

func (a *Agent) Close() error {
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return nil
	}
	a.closed = true
	a.cancel()
	servers := make([]*http.Server, 0, len(a.servers))
	for s := range a.servers {
		servers = append(servers, s)
	}
	a.mu.Unlock()

	var errs []error
	for _, s := range servers {
		if err := s.Close(); err != nil {
			errs = append(errs, err)
		}
	}
	a.wg.Wait()
	a.requests.Wait()

	a.execMu.Lock()
	for _, e := range a.execs {
		if !e.proc.Exited() {
			if err := e.proc.Kill(); err != nil {
				errs = append(errs, err)
			}
		}
	}
	a.execMu.Unlock()

	if err := a.cleanParts(); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

func (a *Agent) cleanParts() error {
	a.writeMu.Lock()
	defer a.writeMu.Unlock()
	var errs []error
	for part := range a.parts {
		if err := os.Remove(part); err != nil && !os.IsNotExist(err) {
			errs = append(errs, err)
		}
		delete(a.parts, part)
	}
	return errors.Join(errs...)
}

type response struct {
	code  int
	value any
}

func ok(v any) response {
	return response{http.StatusOK, v}
}

func failure(code int, msg string) response {
	return response{code, map[string]any{"error": msg}}
}

func actionError(err error) response {
	if err == nil {
		return ok(map[string]any{"ok": true})
	}
	code := http.StatusInternalServerError
	switch {
	case errors.Is(err, api.ErrNotSupported):
		code = http.StatusNotImplemented
	case errors.Is(err, api.ErrSafe):
		code = http.StatusForbidden
	case errors.Is(err, api.ErrBusy):
		code = http.StatusConflict
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		code = http.StatusGatewayTimeout
	}
	return failure(code, err.Error())
}

func (a *Agent) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		http.Error(w, "agent: closed: shutting down", http.StatusServiceUnavailable)
		return
	}
	a.requests.Add(1)
	a.mu.Unlock()
	defer a.requests.Done()
	res := a.handle(w, r)
	data, err := json.Marshal(res.value)
	if err != nil {
		res = failure(500, "agent: encode: invalid response")
		data, _ = json.Marshal(res.value)
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Connection", "close")
	w.WriteHeader(res.code)
	_, _ = w.Write(data)

	// Never log query strings (paths can contain user data) or request bodies.
	path := r.URL.Path
	if len(path) > 200 {
		path = path[:200]
	}
	a.d.Log.Info("request", "method", r.Method, "path", path, "code", res.code)
}

func (a *Agent) handle(w http.ResponseWriter, r *http.Request) response {
	auth := r.Header.Get("Authorization")
	expected := "Bearer " + a.token
	if subtle.ConstantTimeCompare([]byte(auth), []byte(expected)) != 1 {
		return failure(403, "forbidden")
	}
	route := strings.Trim(r.URL.Path, "/")
	if !knownRoute(r.Method, route) {
		return failure(404, "нет такой ручки")
	}
	if controlRoute(route) && !a.d.Control() {
		return failure(403, "Управление компьютером запрещено на этом ПК")
	}
	select {
	case a.sem <- struct{}{}:
		defer func() { <-a.sem }()
	default:
		return failure(503, "слишком много запросов (максимум 4)")
	}
	var body []byte
	if r.Method == http.MethodPost {
		if r.ContentLength < 0 || r.Header.Get("Content-Length") == "" {
			return failure(411, "нужен Content-Length")
		}
		limit := a.d.MaxBody
		if route == "update" {
			limit = a.d.MaxDev
		}
		if r.ContentLength > limit {
			return failure(413, "тело слишком большое")
		}
		r.Body = http.MaxBytesReader(w, r.Body, limit)
		defer func() { _ = r.Body.Close() }()
		var err error
		body, err = io.ReadAll(r.Body)
		if err != nil {
			var maxErr *http.MaxBytesError
			if errors.As(err, &maxErr) {
				return failure(413, "тело слишком большое")
			}
			return failure(400, "agent: body: incomplete request")
		}
	}
	return a.dispatch(r, route, body)
}

func knownRoute(method, route string) bool {
	if method == http.MethodGet {
		switch route {
		case "status", "log", "proc", "procs", "read", "files", "exposed":
			return true
		}
	}
	if method == http.MethodPost {
		switch route {
		case "exec", "kill", "write", "code", "restart", "switch", "vpn", "expose", "unexpose", "update", "rollback":
			return true
		}
	}
	return false
}

func controlRoute(route string) bool {
	switch route {
	case "exec", "proc", "procs", "kill", "read", "write", "files":
		return true
	}
	return false
}
