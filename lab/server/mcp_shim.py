"""Шим MCP windows_* для Лаборатории: живёт внутри `ra-lab session` (пока есть канал), переводит запросы адаптера в вызовы агента ПК.
Протокол сокета как у codex-bridge-session: одна JSON-строка {op,args,binding} (<=256 КБ) -> одна JSON-строка ответа."""
import base64, hashlib, json, os, re, socket, sys, threading, time, urllib.parse

MAX = 262144
WS_DEFAULT = 'C:\\Users\\user'
OUT_CHARS = 32768
CMD_SLOTS, CONN_SLOTS, PROCS_MAX = 2, 16, 32
ABS = re.compile(r'^[A-Za-z]:[\\/]')


def identity(pc):
    """-> {projectId, hostId, deviceLabel, windowsReplica} (метки как ждёт server_node_catalog)."""
    host = 'lab-' + re.sub(r'[^a-z0-9_-]', '-', pc.lower())[:40]
    if not re.fullmatch(r'[a-z0-9_-]+', pc.lower()):  # не-ASCII/точки: короткий хэш, чтобы разные имена не слились
        host += '-' + hashlib.sha256(pc.encode()).hexdigest()[:8]
    ws = os.environ.get('RA_LAB_WORKSPACE') or WS_DEFAULT
    return {'projectId': 'lab', 'hostId': host, 'deviceLabel': 'win-' + hashlib.sha256(('ralab:' + pc).encode()).hexdigest()[:28], 'windowsReplica': ws}


def sock_path(ident):
    return os.path.join(os.path.expanduser('~/.local/state/codex-remote'), ident['deviceLabel'] + '.sock')


def register(pc, ident):
    """Запись каталога устройств (атомарно, 0600). Ошибка не должна ронять сессию - вызывающий ловит."""
    home = os.path.expanduser('~')
    rec = {'projectId': 'lab', 'hostId': ident['hostId'], 'deviceLabel': ident['deviceLabel'], 'socketPath': sock_path(ident),
           'serverWorkspace': os.path.join(home, 'work/projects/lab'), 'windowsReplica': ident['windowsReplica'], 'allowShell': True,
           'controlOnly': True, 'deviceName': pc[:80], 'projectName': 'Лаборатория'}
    sys.path.insert(0, os.path.expanduser('~/.local/share/codex-remote'))
    import server_node_catalog  # как адаптер: невалидная запись сломала бы records() для всех windows_*
    server_node_catalog.validate(rec, home)
    d = os.path.join(home, '.local/share/remote-agents-nodes', ident['hostId'])
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = os.path.join(d, 'lab.json.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump(rec, f, ensure_ascii=False)
    os.replace(tmp, os.path.join(d, 'lab.json'))


class Shim:
    def __init__(self, ident, ag):
        """ag(method, path, body=None, timeout=15) -> (код|None, объект); None = агент недоступен."""
        self.id, self.ag, self.stop = ident, ag, threading.Event()
        self.cmd_sem, self.conn_sem = threading.Semaphore(CMD_SLOTS), threading.Semaphore(CONN_SLOTS)
        self.procs, self.lock, self.running = {}, threading.Lock(), 0  # id -> [off_out, off_err]
        self.path, self.srv, self.ino, self.thread = sock_path(ident), None, None, None

    # --- жизнь сокета ---
    def start(self):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        try:
            os.remove(self.path)  # побеждает новая сессия
        except FileNotFoundError:
            pass
        s = socket.socket(socket.AF_UNIX)
        s.bind(self.path)
        os.chmod(self.path, 0o600)
        s.listen(8)
        s.settimeout(0.5)
        self.srv, self.ino = s, os.stat(self.path).st_ino
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    def close(self):
        self.stop.set()
        if self.srv:
            self.srv.close()
        if self.thread:
            self.thread.join(3)
        with self.lock:
            left, self.procs = list(self.procs), {}
        for eid in left:  # канал обычно уже закрыт: одна быстрая попытка, при первой ошибке бросаем
            if self.ag('POST', '/kill', {'id': eid}, timeout=1)[0] is None:
                break
        try:
            if os.stat(self.path).st_ino == self.ino:  # не трогаем сокет более новой сессии
                os.remove(self.path)
        except OSError:
            pass

    def loop(self):
        while not self.stop.is_set():
            try:
                c, _ = self.srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            if not self.conn_sem.acquire(blocking=False):
                self.reply(c, {'ok': False, 'reason': 'busy'})
                continue
            threading.Thread(target=self.serve, args=(c,), daemon=True).start()

    @staticmethod
    def reply(c, obj):
        try:
            c.sendall(json.dumps(obj, ensure_ascii=False, separators=(',', ':')).encode() + b'\n')
        except OSError:
            pass
        finally:
            c.close()

    def serve(self, c):
        try:
            c.settimeout(10)
            with c.makefile('rb') as f:
                raw = f.readline(MAX + 1)
            if len(raw) > MAX or not raw.endswith(b'\n'):
                return self.reply(c, {'ok': False, 'reason': 'invalid-request'})
            try:
                req = json.loads(raw)
                if not isinstance(req, dict) or not isinstance(req.get('args', {}), dict):
                    raise ValueError
            except ValueError:
                return self.reply(c, {'ok': False, 'reason': 'invalid-request'})
            b = req.get('binding')
            if b != {k: self.id[k] for k in ('projectId', 'hostId', 'deviceLabel', 'windowsReplica')}:
                return self.reply(c, {'ok': False, 'reason': 'binding-mismatch'})
            c.settimeout(None)
            try:
                res = self.dispatch(str(req.get('op')), req.get('args', {}))
            except Exception:  # не пускаем исключение и тексты наружу
                res = {'ok': False, 'reason': 'internal-error'}
            self.reply(c, res)
        except OSError:
            c.close()
        finally:
            self.conn_sem.release()

    # --- трансляция ---
    def wpath(self, p):
        p = str(p or '')
        if ABS.match(p):
            return p
        ws = self.id['windowsReplica'].rstrip('\\')
        parts = [x for x in re.split(r'[\\/]+', p) if x]
        if '..' in parts:
            raise ValueError('path')
        return '\\'.join([ws] + parts)

    def dispatch(self, op, a):
        code, st = self.ag('GET', '/status', timeout=10)
        if code == 503:
            return {'ok': False, 'reason': 'busy'}
        if code != 200:
            return {'ok': False, 'reason': 'tunnel-down'}
        i = self.id
        if op == 'status':
            return {'ok': True, 'device': i['deviceLabel'], 'platform': 'windows', 'workspace': i['windowsReplica'], 'shell_enabled': True, 'control_only': True,
                    'project_id': i['projectId'], 'host_id': i['hostId'], 'capabilities': {}, 'coordination': {'exclusive': True}}
        try:
            if op == 'list':
                code, r = self.ag('GET', '/files?path=' + urllib.parse.quote(self.wpath(a.get('path')), safe=''))
                if code != 200:
                    return {'ok': False, 'error': 'Path not available.'}
                es = [{'name': e['name'], 'directory': bool(e['dir']), 'length': 0 if e['dir'] else (e.get('size') or 0)} for e in r.get('entries', [])[:200]]
                return {'ok': True, 'entries': es, 'limit': 200}
            if op == 'read':
                code, r = self.ag('GET', '/read?length=65537&path=' + urllib.parse.quote(self.wpath(a.get('path')), safe=''))
                if code != 200:
                    return {'ok': False, 'error': 'File not available.'}
                if r.get('size', 0) > 65536:
                    return {'ok': False, 'error': 'File exceeds 64 KiB.'}
                return {'ok': True, 'content': base64.b64decode(r['b64']).decode('utf-8', 'replace')}
            if op == 'write':
                data = str(a.get('content', '')).encode('utf-8')
                if len(data) > 65536:
                    return {'ok': False, 'error': 'Content exceeds 64 KiB.'}
                code, r = self.ag('POST', '/write', {'path': self.wpath(a.get('path')), 'b64': base64.b64encode(data).decode(), 'offset': 0, 'done': True})
                return {'ok': True, 'bytes': len(data)} if code == 200 else {'ok': False, 'error': 'Write failed.'}
        except ValueError:
            return {'ok': False, 'error': 'Path outside workspace.'}
        if op == 'command':
            return self.command(a)
        if op == 'process_start':
            return self.pstart(a)
        if op == 'process_poll':
            return self.ppoll(a)
        if op == 'process_stop':
            return self.pstop(a)
        return {'ok': False, 'reason': 'unsupported'}

    def start_exec(self, a):
        body = {'cmd': str(a.get('command', '')), 'shell': 'powershell'}
        if a.get('cwd'):
            body['cwd'] = self.wpath(a['cwd'])
        if not body['cmd']:
            return None, {'ok': False, 'error': 'Empty command.'}
        code, r = self.ag('POST', '/exec', body)
        if code in (429, 503):
            return None, {'ok': False, 'reason': 'busy'}
        if code != 200 or 'id' not in r:
            return None, {'ok': False, 'error': 'Could not start process.'}
        return str(r['id']), None

    def pull(self, eid, offs, wait, timeout):
        """Новый вывод с запомненных смещений -> (код, объект, байты); offs обновляется."""
        code, r = self.ag('GET', '/proc?id=%s&out=%d&err=%d&wait=%d' % (urllib.parse.quote(eid, safe=''), offs[0], offs[1], 1 if wait else 0), timeout=timeout)
        if code != 200:
            return code, r, b''
        offs[0], offs[1] = r['out_off'], r['err_off']
        return code, r, base64.b64decode(r['out_b64']) + base64.b64decode(r['err_b64'])

    @staticmethod
    def text(buf):
        return bytes(buf).decode('utf-8', 'replace')[-OUT_CHARS:]

    def command(self, a):
        try:
            tmo = max(1, min(60, int(a.get('timeout_seconds') or 30)))
        except (TypeError, ValueError):
            return {'ok': False, 'error': 'Timeout must be 1..60 seconds.'}
        if not self.cmd_sem.acquire(blocking=False):
            return {'ok': False, 'reason': 'busy'}
        with self.lock:  # exclusive: отказ, если есть другая команда или отслеживаемый процесс; проверка и учёт атомарны
            if a.get('exclusive') is True and (self.running or self.procs):
                self.cmd_sem.release()
                return {'ok': False, 'reason': 'busy'}
            self.running += 1
        eid, finished = None, False
        try:
            try:
                eid, err = self.start_exec(a)
            except ValueError:
                return {'ok': False, 'error': 'Path outside workspace.'}
            if err:
                return err
            end, offs, buf, timed_out, r = time.time() + tmo, [0, 0], bytearray(), False, {}
            while True:
                rem = end - time.time()
                if rem <= 0 or self.stop.is_set():
                    timed_out = True
                    break
                code, r, b = self.pull(eid, offs, True, rem + 2)
                buf += b
                del buf[:-4 * OUT_CHARS]
                if code is None:  # длинный опрос не вернулся к сроку или канал упал
                    timed_out = time.time() >= end - 0.5
                    if not timed_out:
                        return {'ok': False, 'reason': 'tunnel-down'}
                    break
                if code == 503:
                    return {'ok': False, 'reason': 'busy'}
                if code != 200:
                    return {'ok': False, 'error': 'Process lost.'}
                if r.get('exited'):
                    finished = True
                    break
            if timed_out:
                self.ag('POST', '/kill', {'id': eid}, timeout=5)
                buf += self.pull(eid, offs, False, 5)[2]
            finished = True  # вышел сам либо /kill уже отправлен
            return {'ok': True, 'exit_code': r.get('code') if isinstance(r.get('code'), int) and not timed_out else None,
                    'output': self.text(buf), 'timed_out': timed_out, 'output_limit_chars': OUT_CHARS}
        finally:
            if eid and not finished:  # ранний выход: не оставляем бесхозный процесс на ПК (одна быстрая попытка)
                self.ag('POST', '/kill', {'id': eid}, timeout=2)
            with self.lock:
                self.running -= 1
            self.cmd_sem.release()

    def pstart(self, a):
        with self.lock:
            if len(self.procs) >= PROCS_MAX or (a.get('exclusive') is True and (self.procs or self.running)):
                return {'ok': False, 'reason': 'busy'}
        try:
            eid, err = self.start_exec(a)
        except ValueError:
            return {'ok': False, 'error': 'Path outside workspace.'}
        if err:
            return err
        with self.lock:
            self.procs[eid] = [0, 0]
        return {'ok': True, 'id': eid}

    def ppoll(self, a):
        eid = str(a.get('id', ''))
        with self.lock:
            offs = self.procs.get(eid)
        if offs is None:
            return {'ok': False, 'error': 'Unknown bridge process (or completed output expired/read).'}
        code, r, b = self.pull(eid, offs, False, 15)
        if code is None:
            return {'ok': False, 'reason': 'tunnel-down'}
        if code != 200:
            with self.lock:
                self.procs.pop(eid, None)
            return {'ok': False, 'error': 'Unknown bridge process (or completed output expired/read).'}
        running = not r.get('exited')
        if not running:
            with self.lock:
                self.procs.pop(eid, None)
        return {'ok': True, 'running': running, 'exit_code': None if running else (r.get('code') if isinstance(r.get('code'), int) else None),
                'output': self.text(b), 'output_limit_chars': OUT_CHARS}

    def pstop(self, a):
        eid = str(a.get('id', ''))
        with self.lock:
            known = self.procs.pop(eid, None) is not None
        if not known:
            return {'ok': False, 'error': 'Unknown bridge process (or completed output expired/read).'}
        code, _ = self.ag('POST', '/kill', {'id': eid}, timeout=10)
        return {'ok': True, 'stopped': True} if code in (200, 404) else {'ok': False, 'reason': 'tunnel-down'}
