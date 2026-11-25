// Package agent — агент ПК (v2 agent.py): HTTP на слушателе канала (127.0.0.1) с токеном на каждый запуск.
// Без токена — 403. Права — пользователя программы; каждый запрос пишется в журнал (метод, путь, код, без тела).
package agent

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"remoteagents/internal/api"
	"remoteagents/internal/procs"
)

const (
	codeMax = 5 << 20 // тело /code, если MaxDev не задан
	conc    = 4       // одновременных запросов
	chunk   = 4 << 20 // кусок чтения файла
	listMax = 2000
)

type result struct {
	code  int
	obj   any
	after func() // после отправки ответа
}

type route struct {
	fn   func(r *http.Request, q url.Values, body []byte) result
	ctrl bool // требует включённого «Управления компьютером»
	raw  bool // тело не читать целиком (передаётся в r.Body, ограниченное)
}

type Agent struct {
	d      api.AgentDeps
	token  string
	shell  api.Shell
	sem    chan struct{}
	srv    *http.Server
	routes map[string]route // "METHOD /path"
	once   sync.Once
}

var _ api.AgentHost = (*Agent)(nil)

func New(d api.AgentDeps) (*Agent, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	a := &Agent{d: d, token: base64.RawURLEncoding.EncodeToString(raw), sem: make(chan struct{}, conc)}
	if d.MaxBody <= 0 {
		a.d.MaxBody = 8 << 20
	}
	if d.MaxDev <= 0 {
		a.d.MaxDev = codeMax
	}
	d.Log.Secret(a.token)
	a.shell = d.Shell
	if a.shell == nil {
		a.shell = NewShell(d.Log, procs.New(d.Log, nil))
	}
	a.routes = map[string]route{
		"GET /status":    {fn: a.rStatus},
		"GET /log":       {fn: a.rLog},
		"POST /exec":     {fn: a.rExec, ctrl: true},
		"GET /proc":      {fn: a.rProc, ctrl: true},
		"GET /procs":     {fn: a.rProcs, ctrl: true},
		"POST /kill":     {fn: a.rKill, ctrl: true},
		"GET /read":      {fn: a.rRead, ctrl: true},
		"POST /write":    {fn: a.rWrite, ctrl: true},
		"GET /files":     {fn: a.rFiles, ctrl: true},
		"POST /code":     {fn: a.rCode, raw: true},
		"POST /restart":  {fn: a.rRestart},
		"POST /switch":   {fn: a.rSwitch},
		"POST /vpn":      {fn: a.rVPN},
		"POST /expose":   {fn: a.rExpose},
		"POST /unexpose": {fn: a.rUnexpose},
		"GET /exposed":   {fn: a.rExposed},
	}
	a.srv = &http.Server{Handler: http.HandlerFunc(a.handle)}
	return a, nil
}

func (a *Agent) Token() string { return a.token }

// Serve обслуживает слушателя, пока не Close.
func (a *Agent) Serve(l net.Listener) { _ = a.srv.Serve(l) }

func (a *Agent) Close() error {
	_ = a.shell.KillAll()
	return a.srv.Close()
}

func (a *Agent) control() bool {
	if a.d.Control != nil {
		return a.d.Control()
	}
	return Enabled(a.d.Paths)
}

func send(w http.ResponseWriter, code int, obj any) {
	b, _ := json.Marshal(obj)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(len(b)))
	w.Header().Set("Connection", "close")
	w.WriteHeader(code)
	_, _ = w.Write(b)
}

func errObj(s string) map[string]any { return map[string]any{"error": s} }

func (a *Agent) handle(w http.ResponseWriter, r *http.Request) {
	code := 500
	var after func()
	defer func() {
		a.d.Log.Info("request", "method", r.Method, "path", trunc(r.URL.RequestURI(), 200), "code", code)
		if after != nil {
			after()
		}
	}()
	reply := func(c int, obj any) { code = c; send(w, c, obj) }
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+a.token)) != 1 {
		reply(403, errObj("forbidden"))
		return
	}
	rt, ok := a.routes[r.Method+" /"+strings.Trim(r.URL.Path, "/")]
	if !ok {
		reply(404, errObj("нет такой ручки"))
		return
	}
	if rt.ctrl && !a.control() {
		reply(403, errObj(CtrlText))
		return
	}
	select {
	case a.sem <- struct{}{}:
		defer func() { <-a.sem }()
	default:
		reply(503, errObj(fmt.Sprintf("слишком много запросов (максимум %d)", conc)))
		return
	}
	var body []byte
	if r.Method == "POST" {
		max := a.d.MaxBody
		if rt.raw {
			max = a.d.MaxDev
		}
		if r.ContentLength < 0 {
			reply(411, errObj("нужен Content-Length"))
			return
		}
		if r.ContentLength > max {
			reply(413, errObj("тело слишком большое"))
			return
		}
		if !rt.raw {
			body = make([]byte, r.ContentLength)
			if _, err := io.ReadFull(r.Body, body); err != nil {
				reply(400, errObj("тело не прочитано"))
				return
			}
		}
	}
	res := func() (res result) {
		defer func() { // ошибка ручки не должна ронять агент
			if p := recover(); p != nil {
				res = result{code: 500, obj: errObj(fmt.Sprintf("panic: %v", p))}
			}
		}()
		return rt.fn(r, r.URL.Query(), body)
	}()
	after = res.after
	reply(res.code, res.obj)
}

func trunc(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}

func jsonBody(b []byte) map[string]any {
	var d map[string]any
	if json.Unmarshal([]byte(strings.TrimPrefix(string(b), "\xef\xbb\xbf")), &d) != nil || d == nil {
		return map[string]any{}
	}
	return d
}

func str(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	}
	return fmt.Sprint(v)
}

func truthy(v any) bool {
	switch x := v.(type) {
	case bool:
		return x
	case float64:
		return x != 0
	case string:
		return x != ""
	}
	return false
}

func intq(q url.Values, k string, def int) (int, error) {
	if s := q.Get(k); s != "" {
		return strconv.Atoi(s)
	}
	return def, nil
}

func oserr(err error) string {
	s := err.Error()
	if len(s) > 100 {
		s = s[:100]
	}
	return "OSError: " + s
}

// --- ручки ---

func (a *Agent) rStatus(*http.Request, url.Values, []byte) result {
	return result{code: 200, obj: a.d.Status()}
}

func (a *Agent) rLog(_ *http.Request, q url.Values, _ []byte) result {
	n, err := intq(q, "n", 200)
	if err != nil {
		return result{code: 500, obj: errObj("ValueError: " + err.Error())}
	}
	recs := []any{}
	for _, l := range a.d.Act.LogTail(n) {
		if json.Valid([]byte(l)) {
			recs = append(recs, json.RawMessage(l))
		} else {
			recs = append(recs, l)
		}
	}
	return result{code: 200, obj: map[string]any{"records": recs}}
}

func (a *Agent) rExec(r *http.Request, _ url.Values, body []byte) result {
	d := jsonBody(body)
	cmd, sh := str(d["cmd"]), str(d["shell"])
	if cmd == "" {
		return result{code: 400, obj: errObj("нет cmd")}
	}
	if sh == "" {
		sh = "powershell"
	}
	cwd := str(d["cwd"])
	if cwd == "" {
		cwd, _ = os.UserHomeDir()
	}
	a.d.Log.Info("exec", "shell", sh, "cmd", trunc(cmd, 500), "cwd", str(d["cwd"]))
	e, err := a.shell.Start(r.Context(), api.ExecReq{Cmd: cmd, Shell: sh, Cwd: cwd})
	if errors.Is(err, ErrTooMany) {
		return result{code: 429, obj: errObj("слишком много запущенных процессов")}
	}
	if err != nil {
		return result{code: 500, obj: errObj("не запустить: " + err.Error())}
	}
	if !truthy(d["wait"]) {
		return result{code: 200, obj: map[string]any{"id": e.ID()}}
	}
	for !e.Exited() { // ждём выхода: обычное ожидание события, не опрос
		e.WaitNew(r.Context(), math.MaxInt, math.MaxInt, 0)
		if r.Context().Err() != nil {
			return result{code: 499, obj: errObj("запрос отменён")}
		}
	}
	o, er := e.Read("out", 0), e.Read("err", 0)
	return result{code: 200, obj: map[string]any{"id": e.ID(), "exited": true, "code": e.Code(), "out": string(o.Data), "err": string(er.Data), "truncated": e.Truncated()}}
}

func (a *Agent) rProc(r *http.Request, q url.Values, _ []byte) result {
	e, ok := a.shell.Get(q.Get("id"))
	if !ok {
		return result{code: 404, obj: errObj("нет такого процесса")}
	}
	oo, err1 := intq(q, "out", 0)
	eo, err2 := intq(q, "err", 0)
	if err := errors.Join(err1, err2); err != nil {
		return result{code: 500, obj: errObj("ValueError: " + err.Error())}
	}
	if q.Get("wait") == "1" {
		e.WaitNew(r.Context(), oo, eo, 0)
	}
	o, er := e.Read("out", oo), e.Read("err", eo)
	exited := e.Drained(o.NextOff, er.NextOff)
	var code any
	if e.Exited() {
		code = e.Code()
	}
	return result{code: 200, obj: map[string]any{"id": e.ID(), "out_b64": base64.StdEncoding.EncodeToString(o.Data), "err_b64": base64.StdEncoding.EncodeToString(er.Data),
		"out_off": o.NextOff, "err_off": er.NextOff, "exited": exited, "code": code, "truncated": e.Truncated()}}
}

func (a *Agent) rProcs(*http.Request, url.Values, []byte) result {
	list := []map[string]any{}
	for _, e := range a.shell.List() {
		var code any
		if e.Exited() {
			code = e.Code()
		}
		cmd := ""
		if c, ok := e.(interface{ Cmd() string }); ok {
			cmd = trunc(c.Cmd(), 80)
		}
		list = append(list, map[string]any{"id": e.ID(), "cmd": cmd, "exited": e.Exited(), "code": code})
	}
	return result{code: 200, obj: map[string]any{"procs": list}}
}

func (a *Agent) rKill(_ *http.Request, _ url.Values, body []byte) result {
	e, ok := a.shell.Get(str(jsonBody(body)["id"]))
	if !ok {
		return result{code: 404, obj: errObj("нет такого процесса")}
	}
	_ = e.Kill()
	return result{code: 200, obj: map[string]any{"ok": true}}
}

func (a *Agent) rRead(_ *http.Request, q url.Values, _ []byte) result {
	off, err1 := intq(q, "offset", 0)
	ln, err2 := intq(q, "length", chunk)
	if err := errors.Join(err1, err2); err != nil {
		return result{code: 500, obj: errObj("ValueError: " + err.Error())}
	}
	if ln < 0 || ln > chunk {
		ln = chunk
	}
	f, err := os.Open(q.Get("path"))
	if err != nil {
		return result{code: 404, obj: errObj(oserr(err))}
	}
	defer f.Close()
	st, err := f.Stat()
	if err == nil && off < 0 {
		err = errors.New("negative offset")
	}
	if err != nil {
		return result{code: 404, obj: errObj(oserr(err))}
	}
	data := make([]byte, ln)
	n, err := f.ReadAt(data, int64(off))
	if err != nil && !errors.Is(err, io.EOF) {
		return result{code: 404, obj: errObj(oserr(err))}
	}
	data = data[:n]
	return result{code: 200, obj: map[string]any{"size": st.Size(), "offset": off, "b64": base64.StdEncoding.EncodeToString(data), "eof": int64(off+n) >= st.Size()}}
}

func (a *Agent) rWrite(_ *http.Request, _ url.Values, body []byte) result {
	d := jsonBody(body)
	bad := result{code: 400, obj: errObj("нужны path, b64 (offset, done необязательно)")}
	path := str(d["path"])
	if path == "" {
		return bad
	}
	data, err := base64.StdEncoding.DecodeString(str(d["b64"]))
	if err != nil {
		return bad
	}
	off := 0
	if v, ok := d["offset"].(float64); ok {
		off = int(v)
	}
	done := true
	if v, ok := d["done"]; ok {
		done = truthy(v)
	}
	part := path + ".ralab-part" // временный файл + rename: файл появляется целым
	abs, _ := filepath.Abs(path)
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		return result{code: 500, obj: errObj(oserr(err))}
	}
	flags := os.O_WRONLY | os.O_CREATE | os.O_TRUNC
	if off != 0 {
		if _, err := os.Stat(part); err != nil {
			return result{code: 409, obj: errObj("нет начала файла (offset > 0 без предыдущих кусков)")}
		}
		flags = os.O_WRONLY
	}
	f, err := os.OpenFile(part, flags, 0o644)
	if err == nil {
		_, err = f.WriteAt(data, int64(off))
		if cerr := f.Close(); err == nil {
			err = cerr
		}
	}
	if err == nil && done {
		err = os.Rename(part, path)
	}
	if err != nil {
		return result{code: 500, obj: errObj(oserr(err))}
	}
	return result{code: 200, obj: map[string]any{"ok": true, "written": len(data), "done": done}}
}

func (a *Agent) rFiles(_ *http.Request, q url.Values, _ []byte) result {
	path := q.Get("path")
	if path == "" {
		path, _ = os.UserHomeDir()
	}
	ents, err := os.ReadDir(path)
	if err != nil {
		return result{code: 404, obj: errObj(oserr(err))}
	}
	out := []map[string]any{}
	for _, e := range ents {
		if len(out) >= listMax {
			break
		}
		it := map[string]any{"name": e.Name(), "dir": false, "size": nil, "mtime": nil}
		if st, err := e.Info(); err == nil {
			it["dir"], it["size"], it["mtime"] = e.IsDir(), st.Size(), st.ModTime().Unix()
		}
		out = append(out, it)
	}
	return result{code: 200, obj: map[string]any{"path": path, "entries": out}}
}

func (a *Agent) restartAfter() func() {
	return func() {
		if err := a.d.Act.Restart(context.Background()); err != nil {
			a.d.Log.Warn("restart", "err", err.Error())
		}
	}
}

// rCode: присланный код/EXE. Тело не буферизуется: идёт потоком в Actions.InstallDev; после ответа — перезапуск (как v2).
func (a *Agent) rCode(r *http.Request, _ url.Values, _ []byte) result {
	err := a.d.Act.InstallDev(r.Context(), io.LimitReader(r.Body, r.ContentLength), r.Header.Get("X-Sha256"), r.Header.Get("X-Version"))
	if err != nil {
		return result{code: 422, obj: map[string]any{"ok": false, "errors": []string{err.Error()}}}
	}
	return result{code: 200, obj: map[string]any{"ok": true}, after: a.restartAfter()}
}

func (a *Agent) rRestart(*http.Request, url.Values, []byte) result {
	return result{code: 200, obj: map[string]any{"ok": true}, after: a.restartAfter()}
}

func (a *Agent) rSwitch(_ *http.Request, _ url.Values, body []byte) result {
	p := str(jsonBody(body)["path"])
	if p == "" {
		return result{code: 400, obj: errObj("нужен path")}
	}
	if err := a.d.Act.SwitchPath(p); err != nil {
		return result{code: 400, obj: errObj(err.Error())}
	}
	return result{code: 200, obj: map[string]any{"ok": true}}
}

func (a *Agent) rVPN(_ *http.Request, _ url.Values, body []byte) result {
	m := str(jsonBody(body)["mode"])
	if m != "off" && m != "auto" && m != "only" {
		return result{code: 400, obj: errObj("режим: off, auto или only")}
	}
	if err := a.d.Act.VPN(m); err != nil {
		return result{code: 409, obj: errObj(err.Error())}
	}
	st := a.d.Status()
	if v, ok := st["vpn"]; ok {
		return result{code: 200, obj: v}
	}
	return result{code: 200, obj: map[string]any{"mode": m}}
}

func url_(port int) string { return "http://localhost:" + strconv.Itoa(port) }

func (a *Agent) fwd() api.Forwarder {
	if a.d.Fwd == nil {
		return nil
	}
	return a.d.Fwd()
}

var noFwd = result{code: 503, obj: map[string]any{"error": "forward-not-ready"}}

func (a *Agent) rExpose(_ *http.Request, _ url.Values, body []byte) result {
	f := a.fwd()
	if f == nil {
		return noFwd
	}
	d := jsonBody(body)
	name := str(d["name"])
	sp, _ := d["serverPort"].(float64)
	pp, _ := d["pcPort"].(float64)
	if name == "" || sp < 1 || sp > 65535 || pp < 0 || pp > 65535 {
		return result{code: 400, obj: errObj("нужны name и serverPort (1–65535)")}
	}
	e, err := f.Expose(name, int(sp), int(pp))
	if err != nil {
		return result{code: 409, obj: errObj(err.Error())}
	}
	return result{code: 200, obj: map[string]any{"ok": true, "name": e.Name, "serverPort": e.ServerPort, "pcPort": e.PCPort, "url": url_(e.PCPort)}}
}

func (a *Agent) rUnexpose(_ *http.Request, _ url.Values, body []byte) result {
	f := a.fwd()
	if f == nil {
		return noFwd
	}
	name := str(jsonBody(body)["name"])
	if name == "" {
		return result{code: 400, obj: errObj("нужен name")}
	}
	if err := f.Unexpose(name); err != nil {
		return result{code: 400, obj: errObj(err.Error())}
	}
	return result{code: 200, obj: map[string]any{"ok": true, "name": name}}
}

func (a *Agent) rExposed(*http.Request, url.Values, []byte) result {
	f := a.fwd()
	if f == nil {
		return noFwd
	}
	list := []map[string]any{}
	for _, e := range f.List() {
		it := map[string]any{"name": e.Name, "serverPort": e.ServerPort, "pcPort": e.PCPort, "listening": e.Err == "", "url": url_(e.PCPort)}
		if e.Err != "" {
			it["err"] = e.Err
		}
		list = append(list, it)
	}
	return result{code: 200, obj: map[string]any{"exposed": list, "channel": f.InternalSocks() != ""}}
}
