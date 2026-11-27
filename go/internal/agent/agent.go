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
	"path/filepath"
	"strconv"
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
	d              api.AgentDeps
	token          string
	instance       string
	ctx            context.Context
	cancel         context.CancelFunc
	sem            chan struct{}
	mu             sync.Mutex
	closed         bool
	servers        map[*http.Server]struct{}
	listenerTraces map[*http.Server]string
	procTraceID    string
	wg             sync.WaitGroup
	requests       sync.WaitGroup
	execMu         sync.Mutex
	execs          map[string]execution
	writeMu        sync.Mutex
	parts          map[string]struct{}
	started        time.Time
	port           int
}

type execution struct {
	id      string
	cmd     string
	proc    api.ExecProc
	release func()
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
	a := &Agent{
		d:              d,
		token:          token,
		instance:       hex.EncodeToString(secret[32:]),
		ctx:            ctx,
		cancel:         cancel,
		sem:            make(chan struct{}, concMax),
		servers:        make(map[*http.Server]struct{}),
		listenerTraces: make(map[*http.Server]string),
		execs:          make(map[string]execution),
		parts:          make(map[string]struct{}),
		started:        time.Now(),
	}
	// Remove journal staging files left by a crash, even if the main journal
	// has not been created yet. Only this component's reserved names qualify.
	staging, err := filepath.Glob(filepath.Join(d.Paths.State, "agent-parts-*.ralab-tmp"))
	if err != nil {
		cancel()
		return nil, fmt.Errorf("agent: journal staging: %w", err)
	}
	for _, path := range staging {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			cancel()
			return nil, fmt.Errorf("agent: journal staging: %w", err)
		}
	}
	if d.Traces != nil {
		exe, err := os.Executable()
		if err != nil {
			exe = os.Args[0]
		}
		procID := fmt.Sprintf("agent-%d", time.Now().UnixNano())
		if err := d.Traces.Intent(api.Trace{
			Kind:     "process",
			ID:       procID,
			Instance: d.Traces.Instance(),
			Owner:    "agent",
			Data: map[string]string{
				"exe":  exe,
				"home": d.Paths.Home,
			},
		}); err != nil {
			cancel()
			return nil, fmt.Errorf("agent: trace intent: %w", err)
		}
		if err := d.Traces.Applied("process", procID, map[string]string{
			"pid":   strconv.Itoa(os.Getpid()),
			"start": a.started.UTC().Format(time.RFC3339Nano),
		}, nil); err != nil {
			_ = d.Traces.Done("process", procID)
			cancel()
			return nil, fmt.Errorf("agent: trace applied: %w", err)
		}
		a.procTraceID = procID
	}
	data, err := os.ReadFile(a.partsJournal())
	if err != nil && !os.IsNotExist(err) {
		if a.procTraceID != "" && d.Traces != nil {
			_ = d.Traces.Done("process", a.procTraceID)
		}
		cancel()
		return nil, fmt.Errorf("agent: uploads: %w", err)
	}
	if err == nil {
		if err = json.Unmarshal(data, &a.parts); err == nil {
			if a.parts == nil {
				a.parts = make(map[string]struct{})
			}
			for part := range a.parts {
				if !filepath.IsAbs(part) || !strings.HasSuffix(part, ".ralab-part") {
					err = errors.New("invalid upload journal path")
					break
				}
			}
			if err == nil {
				err = a.cleanParts()
			}
		}
		if err != nil {
			if a.procTraceID != "" && d.Traces != nil {
				_ = d.Traces.Done("process", a.procTraceID)
			}
			cancel()
			return nil, fmt.Errorf("agent: uploads: %w", err)
		}
	}
	return a, nil
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

	addr := l.Addr().String()
	traceID := fmt.Sprintf("agent-listener-%d", time.Now().UnixNano())
	if a.d.Traces != nil {
		if err := a.d.Traces.Intent(api.Trace{
			Kind:     "listener",
			ID:       traceID,
			Owner:    "agent",
			Instance: a.d.Traces.Instance(),
			Data:     map[string]string{"addr": addr},
		}); err != nil {
			a.d.Log.Warn("serve", "trace-intent", err.Error())
			_ = l.Close()
			return
		}
		if err := a.d.Traces.Applied("listener", traceID, map[string]string{"addr": addr}, nil); err != nil {
			a.d.Log.Warn("serve", "trace-applied", err.Error())
			_ = a.d.Traces.Done("listener", traceID)
			_ = l.Close()
			return
		}
	}

	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		if a.d.Traces != nil {
			_ = a.d.Traces.Done("listener", traceID)
		}
		_ = l.Close()
		return
	}
	a.servers[srv] = struct{}{}
	a.listenerTraces[srv] = traceID
	if addr, ok := l.Addr().(*net.TCPAddr); ok {
		a.port = addr.Port
	}
	a.wg.Add(1)
	a.mu.Unlock()

	go func() {
		defer a.wg.Done()
		defer func() {
			if a.d.Traces != nil {
				_ = a.d.Traces.Done("listener", traceID)
			}
		}()
		err := srv.Serve(l)
		_ = srv.Close()
		a.mu.Lock()
		delete(a.servers, srv)
		delete(a.listenerTraces, srv)
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

	a.mu.Lock()
	for _, id := range a.listenerTraces {
		if a.d.Traces != nil {
			_ = a.d.Traces.Done("listener", id)
		}
	}
	clear(a.listenerTraces)
	a.mu.Unlock()

	if a.d.Traces != nil && a.procTraceID != "" {
		if err := a.d.Traces.Done("process", a.procTraceID); err != nil {
			errs = append(errs, err)
		}
	}

	a.execMu.Lock()
	for _, e := range a.execs {
		e.release()
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
			continue
		}
		delete(a.parts, part)
	}
	if err := a.saveParts(); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

func (a *Agent) partsJournal() string {
	return filepath.Join(a.d.Paths.State, "agent-parts.json")
}

// saveParts commits ownership before creating a part. A failed commit must
// prevent the upload; a completed rename/removal makes a stale entry harmless.
func (a *Agent) saveParts() error {
	if err := os.MkdirAll(a.d.Paths.State, 0700); err != nil {
		return err
	}
	data, err := json.Marshal(a.parts)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(a.d.Paths.State, "agent-parts-*.ralab-tmp")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(f.Name()) }()
	_, writeErr := f.Write(data)
	if writeErr == nil {
		writeErr = f.Sync()
	}
	closeErr := f.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		return err
	}
	return os.Rename(f.Name(), a.partsJournal())
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
	if r.Method == http.MethodGet && res.code < 400 {
		return // успешные чтения не пишем: они вытесняли события канала; ошибки и изменяющие запросы остаются
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
	if route == "exec" {
		var req struct {
			Wait bool `json:"wait"`
		}
		if json.Unmarshal(body, &req) == nil && req.Wait {
			rc := http.NewResponseController(w)
			if err := rc.SetWriteDeadline(time.Time{}); err != nil {
				return failure(500, "agent: deadline: cannot wait for execution")
			}
			defer func() { _ = rc.SetWriteDeadline(time.Now().Add(35 * time.Second)) }()
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
