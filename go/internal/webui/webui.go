package webui

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
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

//go:embed static/index.html
var embeddedIndexHTML []byte

type UI struct {
	act       api.Actions
	log       api.Logger
	devAssets string
	token     string
	port      int
	url       string

	mu        sync.Mutex
	listener  net.Listener
	srv       *http.Server
	started   bool
	stopWatch func() bool
	stopped   bool
}

func (u *UI) Name() string { return "webui" }

func (u *UI) URL() string { return u.url }

func (u *UI) Status() map[string]any {
	u.mu.Lock()
	defer u.mu.Unlock()
	return map[string]any{
		"url":     u.url,
		"port":    u.port,
		"started": u.started,
		"stopped": u.stopped,
	}
}

func New(act api.Actions, log api.Logger, devAssets string) (*UI, error) {
	if act == nil {
		return nil, errors.New("webui: invalid-args: act is required")
	}
	if log == nil {
		return nil, errors.New("webui: invalid-args: log is required")
	}

	tokBytes := make([]byte, 24)
	if _, err := rand.Read(tokBytes); err != nil {
		return nil, fmt.Errorf("webui: token-gen-failed: %w", err)
	}
	token := base64.RawURLEncoding.EncodeToString(tokBytes)
	log.Secret(token)

	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("webui: bind-failed: %w", err)
	}
	tcpAddr, ok := l.Addr().(*net.TCPAddr)
	if !ok {
		_ = l.Close()
		return nil, errors.New("webui: bind-failed: non-tcp address")
	}

	u := &UI{
		act:       act,
		log:       log,
		devAssets: devAssets,
		token:     token,
		port:      tcpAddr.Port,
		url:       fmt.Sprintf("http://127.0.0.1:%d/?t=%s", tcpAddr.Port, token),
		listener:  l,
	}

	mux := http.NewServeMux()
	u.registerHandlers(mux)

	u.srv = &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	return u, nil
}

func (u *UI) Start(ctx context.Context) error {
	u.mu.Lock()
	defer u.mu.Unlock()

	if u.stopped {
		return errors.New("webui: already-stopped: cannot start")
	}
	if u.started {
		return nil
	}
	if u.listener == nil {
		return errors.New("webui: no-listener: listener is nil")
	}
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("webui: start-canceled: %w", err)
	}
	u.started = true
	u.stopWatch = context.AfterFunc(ctx, func() { _ = u.srv.Close() })

	go func() {
		if err := u.srv.Serve(u.listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			u.log.Error("webui: serve-error", "err", err)
		}
	}()
	return nil
}

func (u *UI) Stop(ctx context.Context) error {
	u.mu.Lock()
	defer u.mu.Unlock()

	if u.stopped {
		return nil
	}
	u.stopped = true

	if u.srv == nil {
		return nil
	}

	if u.stopWatch != nil {
		u.stopWatch()
	}
	// Close the reserved socket even when Start was never called.
	if !u.started {
		_ = u.listener.Close()
		return nil
	}
	if err := u.srv.Shutdown(ctx); err != nil {
		_ = u.srv.Close()
		return fmt.Errorf("webui: stop-failed: %w", err)
	}
	return nil
}

func (u *UI) registerHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/", u.handleIndex)
	mux.HandleFunc("/state", u.handleState)
	mux.HandleFunc("/api/status", u.handleState)
	mux.HandleFunc("/api/update", u.handleUpdate)
	mux.HandleFunc("/update", u.handleUpdate)
	mux.HandleFunc("/api/log/tail", u.handleLogTail)
	mux.HandleFunc("/api/log/zip", u.handleLogZip)
	mux.HandleFunc("/api/log/send", u.handleLogSend)
	mux.HandleFunc("/api/check", u.handleCheck)
	mux.HandleFunc("/check", u.handleCheck)
	mux.HandleFunc("/api/happier", u.handleHappier)
	mux.HandleFunc("/api/control", u.handleControl)
	mux.HandleFunc("/control", u.handleControl)
	mux.HandleFunc("/api/config/check", u.handleConfigCheck)
	mux.HandleFunc("/api/config/apply", u.handleConfigApply)
	mux.HandleFunc("/config", u.handleConfigApply)
	mux.HandleFunc("/api/config/revert", u.handleConfigRevert)
	mux.HandleFunc("/revert", u.handleConfigRevert)
	mux.HandleFunc("/api/exit", u.handleExit)
	mux.HandleFunc("/exit", u.handleExit)
}

func (u *UI) checkAuth(w http.ResponseWriter, req *http.Request) bool {
	expectedHost := fmt.Sprintf("127.0.0.1:%d", u.port)
	if req.Host != expectedHost {
		http.Error(w, "Доступ закрыт", http.StatusForbidden)
		return false
	}

	tok := req.URL.Query().Get("t")
	if tok == "" {
		tok = req.Header.Get("X-Token")
	}
	if tok == "" || subtle.ConstantTimeCompare([]byte(tok), []byte(u.token)) != 1 {
		http.Error(w, "Доступ закрыт", http.StatusForbidden)
		return false
	}
	return true
}

func replyJSON(w http.ResponseWriter, code int, obj any) {
	data, err := json.Marshal(obj)
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.WriteHeader(code)
	_, _ = w.Write(data)
}

func (u *UI) handleIndex(w http.ResponseWriter, req *http.Request) {
	if req.URL.Path != "/" {
		http.NotFound(w, req)
		return
	}
	if !u.checkAuth(w, req) {
		return
	}

	raw := embeddedIndexHTML
	if u.devAssets != "" {
		p := filepath.Join(u.devAssets, "index.html")
		data, err := os.ReadFile(p)
		if err != nil {
			http.Error(w, "webui: assets-unavailable: cannot read index.html", http.StatusInternalServerError)
			return
		}
		raw = data
	}

	rendered := bytes.ReplaceAll(raw, []byte("__T__"), []byte(html.EscapeString(u.token)))
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(rendered)
}

func (u *UI) handleState(w http.ResponseWriter, req *http.Request) {
	if !u.checkAuth(w, req) {
		return
	}
	st := u.act.Status()
	if st == nil {
		st = map[string]any{}
	}
	replyJSON(w, http.StatusOK, st)
}

func (u *UI) handleUpdate(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !u.checkAuth(w, req) {
		return
	}
	if err := u.act.UpdateNow(req.Context()); err != nil {
		replyJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	replyJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (u *UI) handleLogTail(w http.ResponseWriter, req *http.Request) {
	if !u.checkAuth(w, req) {
		return
	}
	n := 100
	if nStr := req.URL.Query().Get("n"); nStr != "" {
		if parsed, err := strconv.Atoi(nStr); err == nil && parsed > 0 {
			n = min(parsed, 10000)
		}
	}
	lines := u.act.LogTail(n)
	if lines == nil {
		lines = []string{}
	}
	replyJSON(w, http.StatusOK, map[string]any{"ok": true, "lines": lines})
}

func (u *UI) handleLogZip(w http.ResponseWriter, req *http.Request) {
	if !u.checkAuth(w, req) {
		return
	}
	var archive bytes.Buffer
	if err := u.act.LogZip(&archive); err != nil {
		u.log.Error("webui: logzip-failed", "err", err)
		replyJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", "attachment; filename=logs.zip")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(archive.Bytes())
}

func (u *UI) handleLogSend(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !u.checkAuth(w, req) {
		return
	}
	if err := u.act.LogSend(req.Context()); err != nil {
		replyJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	replyJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (u *UI) handleCheck(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !u.checkAuth(w, req) {
		return
	}
	items, err := u.act.Leftovers(req.Context())
	if err != nil {
		replyJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error(), "items": []string{}})
		return
	}
	if items == nil {
		items = []string{}
	}
	replyJSON(w, http.StatusOK, map[string]any{"ok": true, "items": items})
}

func (u *UI) handleHappier(w http.ResponseWriter, req *http.Request) {
	if !u.checkAuth(w, req) {
		return
	}
	hURL, err := u.act.HappierURL()
	if err != nil {
		replyJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	replyJSON(w, http.StatusOK, map[string]any{"ok": true, "url": hURL})
}

func (u *UI) handleControl(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !u.checkAuth(w, req) {
		return
	}
	if !parseForm(w, req) {
		return
	}
	onVal := req.PostFormValue("on")
	on := onVal == "1" || strings.EqualFold(onVal, "true")
	if err := u.act.SetControl(on); err != nil {
		replyJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	replyJSON(w, http.StatusOK, map[string]any{"ok": true, "control": on})
}

func (u *UI) handleConfigCheck(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !u.checkAuth(w, req) {
		return
	}
	if !parseForm(w, req) {
		return
	}
	text := req.PostFormValue("text")
	pw := req.PostFormValue("password")
	u.log.Secret(pw)
	if err := u.act.ConfigCheck([]byte(text), pw); err != nil {
		replyJSON(w, http.StatusOK, map[string]any{"ok": false, "problems": []string{err.Error()}})
		return
	}
	replyJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (u *UI) handleConfigApply(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !u.checkAuth(w, req) {
		return
	}
	if !parseForm(w, req) {
		return
	}
	text := req.PostFormValue("text")
	pw := req.PostFormValue("password")
	u.log.Secret(pw)
	if err := u.act.ConfigApply(req.Context(), []byte(text), pw); err != nil {
		replyJSON(w, http.StatusOK, map[string]any{"ok": false, "problems": []string{err.Error()}})
		return
	}
	replyJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (u *UI) handleConfigRevert(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !u.checkAuth(w, req) {
		return
	}
	if err := u.act.ConfigRevert(req.Context()); err != nil {
		replyJSON(w, http.StatusOK, map[string]any{"ok": false, "problems": []string{err.Error()}})
		return
	}
	replyJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (u *UI) handleExit(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !u.checkAuth(w, req) {
		return
	}
	replyJSON(w, http.StatusOK, map[string]any{"ok": true})
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(req.Context()), 30*time.Second)
		defer cancel()
		if err := u.act.Exit(ctx); err != nil {
			u.log.Error("webui: exit-failed", "err", err)
		}
	}()
}

func parseForm(w http.ResponseWriter, req *http.Request) bool {
	req.Body = http.MaxBytesReader(w, req.Body, 2<<20)
	if err := req.ParseForm(); err != nil {
		replyJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "webui: invalid-form: invalid or oversized form"})
		return false
	}
	return true
}
