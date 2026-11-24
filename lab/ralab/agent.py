"""Агент ПК: HTTP на 127.0.0.1:0 с токеном (secrets.token_urlsafe(32), на каждый запуск). Без токена - 403.

Без урезаний относительно старого моста: команда, долгий процесс (старт/опрос/стоп), файлы любого размера (кусками), список файлов,
журнал, плюс присланный код. Права - пользователя EXE; каждый запрос пишется в журнал (метод, путь, код ответа, без тела).
Пределы: тело запроса 8 МБ (/code 5 МБ), одновременно 4 запроса, вывод процесса 1 МБ на поток (старое отбрасывается, truncated),
процессов в списке 64, кусок чтения 4 МБ, список файлов 2000.
Сервер без poll-таймера: handle_request() без таймаута блокируется до подключения.
"""
import base64, hmac, json, os, secrets, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import journal, procs
from .bus import bus

BODY_MAX, CODE_MAX, CONC, OUT_MAX, EXEC_MAX, CHUNK, LIST_MAX = 8 << 20, 5 << 20, 4, 1 << 20, 64, 4 << 20, 2000
WIN = sys.platform == 'win32'


class Exec:
    def __init__(self, eid, cmd, shell):
        self.id, self.cmd, self.shell = eid, cmd, shell
        self.cv = threading.Condition()
        self.buf = {'out': bytearray(), 'err': bytearray()}
        self.base = {'out': 0, 'err': 0}  # сколько байт отброшено спереди
        self.truncated, self.exited, self.code = False, False, None

    def add(self, which, data):
        with self.cv:
            b = self.buf[which]
            b += data
            if len(b) > OUT_MAX:
                cut = len(b) - OUT_MAX
                del b[:cut]
                self.base[which] += cut
                self.truncated = True
            self.cv.notify_all()

    def finish(self, code):
        with self.cv:
            self.exited, self.code = True, code
            self.cv.notify_all()

    def chunk(self, which, off):
        """Байты потока с абсолютного смещения off -> (данные, новое смещение). Вызывать под cv."""
        b, base = self.buf[which], self.base[which]
        off = max(off, base)
        data = bytes(b[off - base:off - base + OUT_MAX])
        return data, off + len(data)


def build_command(cmd, shell):
    if WIN:
        if shell == 'cmd':
            return 'cmd.exe /d /s /c "chcp 65001>nul & %s"' % cmd  # одна строка командной строки: кавычки cmd не экранируются как у списка
        script = '[Console]::OutputEncoding=[Text.Encoding]::UTF8\n' + cmd
        return ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand',
                base64.b64encode(script.encode('utf-16-le')).decode()]
    return ['/bin/sh', '-c', cmd]


class Agent:
    def __init__(self, ctx):
        self.ctx, self.token, self.port = ctx, secrets.token_urlsafe(32), 0
        journal.register(self.token)
        self.sem = threading.BoundedSemaphore(CONC)
        self.execs, self.seq, self.lock = {}, 0, threading.Lock()
        self.routes = {('GET', 'status'): self.r_status, ('GET', 'log'): self.r_log, ('POST', 'exec'): self.r_exec, ('GET', 'proc'): self.r_proc,
                       ('GET', 'procs'): self.r_procs, ('POST', 'kill'): self.r_kill, ('GET', 'read'): self.r_read, ('POST', 'write'): self.r_write,
                       ('GET', 'files'): self.r_files, ('POST', 'code'): self.r_code, ('POST', 'restart'): self.r_restart, ('POST', 'switch'): self.r_switch,
                       ('POST', 'vpn'): self.r_vpn}
        bus.subscribe('app.start', self._on_start)
        bus.subscribe('proc.exited', self._on_exit)

    def _on_start(self, _):
        agent = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                agent.handle(self, 'GET')

            def do_POST(self):
                agent.handle(self, 'POST')

        class Srv(ThreadingHTTPServer):
            daemon_threads = True
        srv = Srv(('127.0.0.1', 0), H)
        self.port = srv.server_address[1]

        def loop():
            while True:
                srv.handle_request()  # без таймаута: блокируется до подключения
        threading.Thread(target=loop, name='agent', daemon=True).start()
        bus.publish('agent.ready', {'port': self.port})

    def _on_exit(self, ev):
        if ev['name'].startswith('exec:'):
            e = self.execs.get(ev['name'][5:])
            e and e.finish(ev['code'])

    # --- HTTP ---
    @staticmethod
    def send(h, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        h.send_response(code)
        h.send_header('Content-Type', 'application/json; charset=utf-8')
        h.send_header('Content-Length', str(len(body)))
        h.send_header('Connection', 'close')
        h.end_headers()
        try:
            h.wfile.write(body)
        except OSError:
            pass

    def handle(self, h, method):
        u = urlparse(h.path)
        route, code, after = u.path.strip('/'), 500, None
        try:
            if not hmac.compare_digest(h.headers.get('Authorization', '').encode(), ('Bearer ' + self.token).encode()):
                code = 403
                return self.send(h, 403, {'error': 'forbidden'})
            fn = self.routes.get((method, route))
            if not fn:
                code = 404
                return self.send(h, 404, {'error': 'нет такой ручки'})
            if not self.sem.acquire(blocking=False):
                code = 503
                return self.send(h, 503, {'error': 'слишком много запросов (максимум %d)' % CONC})
            try:
                body = b''
                if method == 'POST':
                    n = int(h.headers.get('Content-Length') or -1)
                    if n < 0:
                        code = 411
                        return self.send(h, 411, {'error': 'нужен Content-Length'})
                    if n > (CODE_MAX if route == 'code' else BODY_MAX):
                        code = 413
                        return self.send(h, 413, {'error': 'тело слишком большое'})
                    body = h.rfile.read(n)
                res = fn(h, parse_qs(u.query), body)
                code, obj, after = res[0], res[1], (res[2] if len(res) > 2 else None)
            except Exception as e:  # ошибка ручки не должна ронять агент
                code, obj = 500, {'error': '%s: %s' % (e.__class__.__name__, e)}
            finally:
                self.sem.release()
            self.send(h, code, obj)
        finally:
            journal.log('agent', 'request', {'method': method, 'path': h.path[:200], 'code': code})
            after and after()

    @staticmethod
    def _json(body):
        try:
            d = json.loads(body.decode('utf-8-sig'))
            return d if isinstance(d, dict) else {}
        except ValueError:
            return {}

    # --- ручки ---
    def r_status(self, h, q, body):
        return 200, self.ctx.status()

    def r_log(self, h, q, body):
        return 200, {'records': journal.tail(int((q.get('n') or ['200'])[0]))}

    def r_exec(self, h, q, body):
        d = self._json(body)
        cmd, shell = str(d.get('cmd') or ''), d.get('shell') or 'powershell'
        if not cmd:
            return 400, {'error': 'нет cmd'}
        with self.lock:
            if len(self.execs) >= EXEC_MAX:
                done = [k for k, v in self.execs.items() if v.exited]
                if not done:
                    return 429, {'error': 'слишком много запущенных процессов'}
                del self.execs[done[0]]
            self.seq += 1
            eid = str(self.seq)
            e = self.execs[eid] = Exec(eid, cmd, shell)
        journal.log('agent', 'exec', {'id': eid, 'shell': shell, 'cmd': cmd[:500], 'cwd': d.get('cwd')})
        try:
            procs.start('exec:' + eid, build_command(cmd, shell), src='exec', binary=True, cwd=d.get('cwd') or os.path.expanduser('~'),
                        on_out=lambda b: e.add('out', b), on_err=lambda line: e.add('err', line.encode('utf-8', 'replace') + b'\n'))
        except (OSError, ValueError) as ex:
            e.finish(None)
            return 500, {'error': 'не запустить: %s' % ex.__class__.__name__, 'id': eid}
        if not d.get('wait'):
            return 200, {'id': eid}
        with e.cv:
            while not e.exited:
                e.cv.wait()
            o, _ = e.chunk('out', 0)
            r, _ = e.chunk('err', 0)
            return 200, {'id': eid, 'exited': True, 'code': e.code, 'out': o.decode('utf-8', 'replace'), 'err': r.decode('utf-8', 'replace'), 'truncated': e.truncated}

    def r_proc(self, h, q, body):
        """Опрос: вывод с абсолютных смещений out/err; wait=1 - ждать новых данных или выхода (событие, не таймер)."""
        e = self.execs.get((q.get('id') or [''])[0])
        if not e:
            return 404, {'error': 'нет такого процесса'}
        oo, eo, wait = int((q.get('out') or ['0'])[0]), int((q.get('err') or ['0'])[0]), (q.get('wait') or ['0'])[0] == '1'
        with e.cv:
            while wait and not e.exited and oo >= e.base['out'] + len(e.buf['out']) and eo >= e.base['err'] + len(e.buf['err']):
                e.cv.wait()
            o, oo = e.chunk('out', oo)
            r, eo = e.chunk('err', eo)
            return 200, {'id': e.id, 'out_b64': base64.b64encode(o).decode(), 'err_b64': base64.b64encode(r).decode(), 'out_off': oo, 'err_off': eo,
                         'exited': e.exited and oo >= e.base['out'] + len(e.buf['out']) and eo >= e.base['err'] + len(e.buf['err']),
                         'code': e.code, 'truncated': e.truncated}

    def r_procs(self, h, q, body):
        return 200, {'procs': [{'id': e.id, 'cmd': e.cmd[:80], 'exited': e.exited, 'code': e.code} for e in self.execs.values()]}

    def r_kill(self, h, q, body):
        eid = str(self._json(body).get('id'))
        if eid not in self.execs:
            return 404, {'error': 'нет такого процесса'}
        procs.kill('exec:' + eid)
        return 200, {'ok': True}

    def r_read(self, h, q, body):
        path = (q.get('path') or [''])[0]
        off, ln = int((q.get('offset') or ['0'])[0]), min(int((q.get('length') or [str(CHUNK)])[0]), CHUNK)
        try:
            with open(path, 'rb') as f:
                size = os.fstat(f.fileno()).st_size
                f.seek(off)
                data = f.read(ln)
        except OSError as e:
            return 404, {'error': e.__class__.__name__ + ': ' + str(e)[:100]}
        return 200, {'size': size, 'offset': off, 'b64': base64.b64encode(data).decode(), 'eof': off + len(data) >= size}

    def r_write(self, h, q, body):
        d = self._json(body)
        try:
            path, data, off = str(d['path']), base64.b64decode(d.get('b64') or '', validate=True), int(d.get('offset') or 0)
        except (KeyError, ValueError):
            return 400, {'error': 'нужны path, b64 (offset, done необязательно)'}
        part = path + '.ralab-part'  # временный файл + os.replace: файл появляется целым
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        if off and not os.path.exists(part):
            return 409, {'error': 'нет начала файла (offset > 0 без предыдущих кусков)'}
        with open(part, 'r+b' if off else 'wb') as f:
            f.seek(off)
            f.write(data)
        if d.get('done', True):
            os.replace(part, path)
        return 200, {'ok': True, 'written': len(data), 'done': bool(d.get('done', True))}

    def r_files(self, h, q, body):
        path = (q.get('path') or [os.path.expanduser('~')])[0]
        try:
            out = []
            with os.scandir(path) as it:
                for e in it:
                    if len(out) >= LIST_MAX:
                        break
                    try:
                        st = e.stat()
                        out.append({'name': e.name, 'dir': e.is_dir(), 'size': st.st_size, 'mtime': int(st.st_mtime)})
                    except OSError:
                        out.append({'name': e.name, 'dir': False, 'size': None, 'mtime': None})
            return 200, {'path': path, 'entries': out}
        except OSError as e:
            return 404, {'error': e.__class__.__name__ + ': ' + str(e)[:100]}

    def r_code(self, h, q, body):
        res = self.ctx.updater.install(body, h.headers.get('X-Sha256', ''))
        if not res['ok']:
            return 422, res
        return 200, res, lambda: bus.publish('app.restart', {'dir': res['dir'], 'why': 'новый код'})  # после ответа: ассистент получает результат

    def r_restart(self, h, q, body):
        self.ctx.updater.clear_pending()
        return 200, {'ok': True}, lambda: bus.publish('app.restart', {'why': 'команда ассистента'})

    def r_switch(self, h, q, body):
        p = self._json(body).get('path')
        if not p:
            return 400, {'error': 'нужен path'}
        bus.publish('path.switch', {'path': str(p)})
        return 200, {'ok': True}

    def r_vpn(self, h, q, body):
        m = self._json(body).get('mode')
        if not self.ctx.vpn.set_mode(m):
            return 400, {'error': 'режим: off, auto или only'}
        return 200, self.ctx.vpn.status()
