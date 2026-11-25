"""Локальная страница управления: 127.0.0.1:<порт>/?t=<токен>. Токен и Host проверяются на каждый запрос. Только стандартная библиотека."""
import html, json, os, secrets, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import control, journal

try:
    from . import v2config
except ImportError:
    v2config = None
try:
    from . import autostart
except ImportError:
    autostart = None
try:
    from . import cleanup
except ImportError:
    cleanup = None

BODY_MAX = 1100000

PAGE = """<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>RemoteAgents</title>
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
function show(s){S=s;document.getElementById("ver").textContent=s.version;document.getElementById("lines").textContent=s.lines.join("\\n");
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
document.getElementById("chk").onclick=function(){document.getElementById("cres").textContent="Проверяю...";post("/check").then(function(r){document.getElementById("cres").textContent=r.items.length?r.items.join("\\n"):"Чисто"})};
function msg(r){var m=document.getElementById("cmsg");m.className=r.ok?"ok":"err";m.textContent=r.ok?"Конфиг принят, перезапускаю…":(r.problems||[]).join("\\n");m.style.whiteSpace="pre-wrap"}
document.getElementById("cform").onsubmit=function(e){e.preventDefault();var f=new FormData(this),d={};f.forEach(function(v,k){d[k]=v});post("/config",d).then(msg);return false};
poll();setInterval(poll,3000);
</script></body></html>"""


def _config_info(home):
    if v2config is None:
        return {'has': False}
    try:
        st = v2config.status(home) or {}
    except Exception:
        return {'has': False}
    t = st.get('time')
    if isinstance(t, (int, float)):
        import time
        t = time.strftime('%d.%m.%Y %H:%M', time.localtime(t))
    return {'has': bool(st.get('has')), 'name': str(st.get('name') or ''), 'server': str(st.get('server') or ''), 'time': str(t or '')}


def _autostart_default(home):
    try:
        with open(os.path.join(home, 'config', 'active.json'), encoding='utf-8') as f:
            return bool(json.load(f).get('autostart', True))
    except (OSError, ValueError, AttributeError):
        return True


def start(ctx):
    token = secrets.token_urlsafe(24)
    journal.register(token)
    home = ctx.home
    exe = getattr(ctx, 'exe', '') or ''
    log = lambda text: journal.log('webui', 'event', {}, text)

    def send(obj):
        link = getattr(ctx, 'link', None)
        if link:
            link._send(obj)

    def push_state():
        link = getattr(ctx, 'link', None)
        if link:
            link._refresh()

    class H(BaseHTTPRequestHandler):
        server_version = 'RA'

        def log_message(self, *a):
            pass

        def _reply(self, code, body, ctype='application/json; charset=utf-8'):
            data = body if isinstance(body, bytes) else body.encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Frame-Options', 'DENY')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.end_headers()
            self.wfile.write(data)

        def _json(self, obj):
            self._reply(200, json.dumps(obj, ensure_ascii=False))

        def _host_ok(self):
            return self.headers.get('Host') == '127.0.0.1:%d' % self.server.server_address[1]

        def do_GET(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            if not self._host_ok() or not secrets.compare_digest(q.get('t', [''])[0].encode(), token.encode()):
                return self._reply(403, 'Доступ закрыт', 'text/plain; charset=utf-8')
            if u.path == '/state':
                return self._json(self._state())
            if u.path == '/':
                return self._reply(200, PAGE.replace('__T__', html.escape(token)), 'text/html; charset=utf-8')
            self._reply(404, 'Нет такой страницы', 'text/plain; charset=utf-8')

        def do_POST(self):
            u = urlparse(self.path)  # Host и токен (в адресе) проверяются до чтения тела
            if not self._host_ok() or not secrets.compare_digest(parse_qs(u.query).get('t', [''])[0].encode(), token.encode()):
                return self._reply(403, 'Доступ закрыт', 'text/plain; charset=utf-8')
            try:
                n = int(self.headers.get('Content-Length') or 0)
            except ValueError:
                n = -1
            if n < 0 or n > BODY_MAX:
                return self._reply(403, 'Доступ закрыт', 'text/plain; charset=utf-8')
            form = {k: v[0] for k, v in parse_qs(self.rfile.read(n).decode('utf-8', 'replace'), keep_blank_values=True).items()}
            try:
                self._json(self._act(u.path, form))
            except Exception as e:
                log('ошибка запроса %s: %s' % (u.path, e))
                self._json({'ok': False, 'problems': ['Не получилось: %s' % e]})

        def _state(self):
            link = getattr(ctx, 'link', None)
            return {'version': ctx.exe_version or ctx.version, 'lines': list(getattr(link, 'lines', None) or [getattr(link, 'note', '')]),
                    'config': _config_info(home), 'control': control.enabled(home),
                    'autostart': bool(autostart.enabled()) if autostart else False}

        def _act(self, path, form):
            if path == '/config':
                if v2config is None:
                    return {'ok': False, 'problems': ['Эта версия не умеет принимать конфиг.']}
                r = v2config.apply(form.get('text', ''), form.get('password', ''), home)
                if r.get('ok'):
                    if autostart and exe:
                        try:
                            autostart.apply(_autostart_default(home), exe, log)
                        except Exception as e:
                            log('автозапуск не настроен: %s' % e)
                    send({'t': 'restart-exe'})
                return {'ok': bool(r.get('ok')), 'problems': list(r.get('problems') or [])}
            if path == '/revert':
                if v2config is None:
                    return {'ok': False, 'problems': ['Эта версия не умеет возвращать конфиг.']}
                r = v2config.revert(home)
                if r.get('ok'):
                    send({'t': 'restart-exe'})
                return {'ok': bool(r.get('ok')), 'problems': list(r.get('problems') or [])}
            if path == '/control':
                control.set(home, form.get('on') == '1')
                push_state()
                return {'ok': True}
            if path == '/autostart':
                if autostart is None:
                    return {'ok': False, 'problem': 'Эта версия не умеет настраивать автозапуск.'}
                if not exe:
                    return {'ok': False, 'problem': 'Не знаю путь программы.'}
                autostart.apply(form.get('on') == '1', exe, log)
                return {'ok': True}
            if path == '/check':
                return {'ok': True, 'items': list(cleanup.check(home)) if cleanup else []}
            return {'ok': False, 'problems': ['Нет такого действия.']}

    srv = ThreadingHTTPServer(('127.0.0.1', 0), H)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, name='webui', daemon=True).start()
    ctx.webui = srv
    return 'http://127.0.0.1:%d/?t=%s' % (srv.server_address[1], token)
