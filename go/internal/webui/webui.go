// Package webui mirrors v2 webui.py: local control page on 127.0.0.1:<port>/?t=<token>.
// Token and Host are checked on every request. Status lines come from the event bus; the page itself
// refreshes in the browser (JS), not in our code.
package webui

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"

	"remoteagents/internal/api"
	"remoteagents/internal/autostart"
	"remoteagents/internal/bus"
)

const bodyMax = 1100000

// statusTopics: bus events whose latest data forms the status lines on the page.
var statusTopics = []string{"agent.ready", "singbox.started", "channel.up", "vpn.dead", "vpn.exited", "vpn.gave_up", "proc.exited"}

const page = `<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>RemoteAgents</title>
<style>body{font:15px sans-serif;max-width:760px;margin:20px auto;padding:0 12px;color:#222}h1{font-size:20px}
.box{border:1px solid #ccc;border-radius:6px;padding:12px;margin:12px 0}.big{font-size:20px;font-weight:bold}
textarea{width:100%;height:160px;box-sizing:border-box}input[type=password]{width:260px}button{font-size:15px;padding:5px 12px;margin:4px 4px 4px 0}
pre{background:#f4f4f4;padding:8px;white-space:pre-wrap}.err{color:#b00020}.ok{color:#176f2c}</style></head><body>
<h1>RemoteAgents &middot; <span id="ver"></span></h1>
<div class="box"><pre id="lines"></pre></div>
<div class="box"><b>Конфиг</b><div id="cfg"></div>
<form id="cform" method="post" action="/config" style="display:none">
<input type="hidden" name="t" value="__T__">
<textarea name="text" placeholder="Вставьте сюда конфиг"></textarea><br>
Пароль: <input type="password" name="password" autocomplete="off"> <button type="submit">Применить</button></form>
<button id="other" type="button" style="display:none">Вставить другой</button>
<button id="revert" type="button" style="display:none">Вернуть прежний</button>
<div id="cmsg"></div></div>
<div class="box">Управление компьютером: <b id="ctl"></b> <button id="ctlb" type="button"></button></div>
<div class="box"><label><input type="checkbox" id="auto"> Запускать при входе в Windows</label> <span id="amsg"></span></div>
<div class="box"><button id="chk" type="button">Проверить чистоту</button><pre id="cres"></pre></div>
<script>
var T="__T__",S=null;
function post(p,d){var b=new URLSearchParams(d||{});b.set("t",T);return fetch(p+"?t="+T,{method:"POST",body:b}).then(function(r){return r.json()})}
function show(s){S=s;document.getElementById("ver").textContent=s.version;document.getElementById("lines").textContent=s.lines.join("\n");
var c=s.config,e=document.getElementById("cfg");
if(c.has){e.textContent="Конфиг: "+c.name+", сервер "+c.server+", от "+c.time}else{e.innerHTML='<div class="big">Вставьте конфиг, который вам прислали</div>'}
if(c.has){document.getElementById("other").style.display="";document.getElementById("revert").style.display=""}
else{document.getElementById("other").style.display="none";document.getElementById("revert").style.display="none";document.getElementById("cform").style.display=""}
document.getElementById("ctl").textContent=s.control?"разрешено":"запрещено";
document.getElementById("ctlb").textContent=s.control?"Запретить":"Разрешить";
document.getElementById("auto").checked=s.autostart}
function poll(){fetch("/state?t="+T).then(function(r){return r.json()}).then(show).catch(function(){})}
document.getElementById("other").onclick=function(){document.getElementById("cform").style.display=""};
document.getElementById("revert").onclick=function(){post("/revert").then(function(r){msg(r)})};
document.getElementById("ctlb").onclick=function(){post("/control",{on:S.control?"0":"1"}).then(poll)};
document.getElementById("auto").onchange=function(){var x=this.checked;post("/autostart",{on:x?"1":"0"}).then(function(r){document.getElementById("amsg").textContent=r.problem||"";poll()})};
document.getElementById("chk").onclick=function(){document.getElementById("cres").textContent="Проверяю...";post("/check").then(function(r){document.getElementById("cres").textContent=r.items.length?r.items.join("\n"):"Чисто"})};
function msg(r){var m=document.getElementById("cmsg");m.className=r.ok?"ok":"err";m.textContent=r.ok?"Конфиг принят, перезапускаю…":(r.problems||[]).join("\n");m.style.whiteSpace="pre-wrap"}
document.getElementById("cform").onsubmit=function(e){e.preventDefault();var f=new FormData(this),d={};f.forEach(function(v,k){d[k]=v});post("/config",d).then(msg);return false};
poll();setInterval(poll,3000);
</script></body></html>`

// UI is the web page server.
type UI struct {
	act    api.Actions
	log    api.Logger
	bus    *bus.Bus
	exe    string
	token  string
	srv    *http.Server
	ln     net.Listener
	mu     sync.Mutex
	events map[string]map[string]any
	unsubs []func()
}

// New creates the page. exe is the program path for autostart ("" disables the autostart switch).
func New(act api.Actions, log api.Logger, b *bus.Bus, exe string) (*UI, error) {
	buf := make([]byte, 24)
	if _, err := rand.Read(buf); err != nil {
		return nil, err
	}
	u := &UI{act: act, log: log, bus: b, exe: exe, events: map[string]map[string]any{}}
	u.token = base64.RawURLEncoding.EncodeToString(buf)
	log.Secret(u.token)
	return u, nil
}

func (u *UI) Name() string { return "webui" }

func (u *UI) Start(ctx context.Context) error {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	u.ln = ln
	for _, t := range statusTopics {
		t := t
		if d := u.bus.Last(t); d != nil {
			u.events[t] = d
		}
		u.unsubs = append(u.unsubs, u.bus.Subscribe(t, func(ev bus.Event) {
			u.mu.Lock()
			u.events[t] = ev.Data
			u.mu.Unlock()
		}))
	}
	u.srv = &http.Server{Handler: http.HandlerFunc(u.serve)}
	go func() { _ = u.srv.Serve(ln) }()
	return nil
}

func (u *UI) Stop(ctx context.Context) error {
	for _, f := range u.unsubs {
		f()
	}
	if u.srv == nil {
		return nil
	}
	return u.srv.Shutdown(ctx)
}

func (u *UI) Status() map[string]any { return map[string]any{"url": u.URL()} }

// URL is the page address with the token ("" before Start).
func (u *UI) URL() string {
	if u.ln == nil {
		return ""
	}
	return fmt.Sprintf("http://%s/?t=%s", u.ln.Addr().String(), u.token)
}

func (u *UI) reply(w http.ResponseWriter, code int, ctype, body string) {
	h := w.Header()
	h.Set("Content-Type", ctype)
	h.Set("Cache-Control", "no-store")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Referrer-Policy", "no-referrer")
	w.WriteHeader(code)
	_, _ = io.WriteString(w, body)
}

func (u *UI) json(w http.ResponseWriter, v any) {
	b, _ := json.Marshal(v)
	u.reply(w, 200, "application/json; charset=utf-8", string(b))
}

func (u *UI) allowed(r *http.Request) bool {
	if r.Host != u.ln.Addr().String() {
		return false
	}
	t := r.URL.Query().Get("t")
	return subtle.ConstantTimeCompare([]byte(t), []byte(u.token)) == 1
}

func (u *UI) serve(w http.ResponseWriter, r *http.Request) {
	const text = "text/plain; charset=utf-8"
	if !u.allowed(r) { // Host and token are checked before the body is read
		u.reply(w, 403, text, "Доступ закрыт")
		return
	}
	if r.Method == http.MethodPost {
		if r.ContentLength < 0 || r.ContentLength > bodyMax {
			u.reply(w, 403, text, "Доступ закрыт")
			return
		}
		raw, _ := io.ReadAll(io.LimitReader(r.Body, bodyMax))
		q, _ := url.ParseQuery(string(raw))
		u.json(w, u.act_(r.Context(), r.URL.Path, q.Get("text"), q.Get("password"), q.Get("on")))
		return
	}
	switch r.URL.Path {
	case "/state":
		u.json(w, u.state())
	case "/":
		u.reply(w, 200, "text/html; charset=utf-8", strings.ReplaceAll(page, "__T__", html.EscapeString(u.token)))
	default:
		u.reply(w, 404, text, "Нет такой страницы")
	}
}

func (u *UI) lines() []string {
	u.mu.Lock()
	defer u.mu.Unlock()
	keys := make([]string, 0, len(u.events))
	for k := range u.events {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]string, 0, len(keys))
	for _, k := range keys {
		b, _ := json.Marshal(u.events[k])
		out = append(out, k+": "+string(b))
	}
	return out
}

func (u *UI) state() map[string]any {
	st := u.act.Status()
	cfg := map[string]any{"has": false}
	if c, ok := st["config"].(map[string]any); ok {
		cfg = c
	}
	ctl, _ := st["control"].(bool)
	ver, _ := st["version"].(string)
	return map[string]any{"version": ver, "lines": u.lines(), "config": cfg, "control": ctl, "autostart": autostart.Enabled()}
}

func (u *UI) restart() {
	go func() { _ = u.act.Restart(context.Background()) }() // after the reply is written
}

func problems(err error) map[string]any {
	if err != nil {
		return map[string]any{"ok": false, "problems": []string{"Не получилось: " + err.Error()}}
	}
	return map[string]any{"ok": true, "problems": []string{}}
}

func (u *UI) act_(ctx context.Context, path, text, password, on string) any {
	switch path {
	case "/config":
		r := problems(u.act.ConfigApply(ctx, []byte(text), password))
		if r["ok"] == true {
			u.restart()
		}
		return r
	case "/revert":
		r := problems(u.act.ConfigRevert(ctx))
		if r["ok"] == true {
			u.restart()
		}
		return r
	case "/control":
		if err := u.act.SetControl(on == "1"); err != nil {
			return problems(err)
		}
		return map[string]any{"ok": true}
	case "/autostart":
		if u.exe == "" {
			return map[string]any{"ok": false, "problem": "Не знаю путь программы."}
		}
		var err error
		if on == "1" {
			err = autostart.Enable(u.exe)
		} else {
			err = autostart.Disable()
		}
		if err != nil {
			return map[string]any{"ok": false, "problem": err.Error()}
		}
		return map[string]any{"ok": true}
	case "/check":
		items, err := u.act.Leftovers(ctx)
		if err != nil {
			return problems(err)
		}
		if items == nil {
			items = []string{}
		}
		return map[string]any{"ok": true, "items": items}
	}
	return map[string]any{"ok": false, "problems": []string{"Нет такого действия."}}
}
