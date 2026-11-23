#!/usr/bin/env python3
"""ra-lab: серверная часть Лаборатории RemoteAgents (запускается на сервере 109 от пользователя remoteagents, без root).

  ra-lab session ...   служебная: её запускает ssh ПК (проба 64 КиБ и канал), руками не вызывается
  ra-lab wait-up [--deadline 90] [--pc ИМЯ]      ждать подключения ПК
  ra-lab status | log [-n N] | rank | exec "<cmd>" [--shell powershell|cmd] [--max-time S] [--cwd D] | kill <id> |
         read <удалённый путь> [локальный] | write <удалённый путь> <локальный|-> | restart | switch <путь> | push [--wait] |
         collect [--every 20]   (долгая: докачивает журнал ПК в ~/work/logs-in/lab/<ПК>/, живёт и после закрытия лаборатории)
Состояние: ~/.local/state/ra-lab/ (0700): <ПК>.json {port, token, version, rollback} (0600) и <ПК>.events (unix-сокет wait-up).
Токен агента никогда не печатается. Стандартная библиотека, Python 3.8+.
"""
import argparse, base64, codecs, datetime, glob, hashlib, io, json, os, socket, subprocess, sys, threading, time, urllib.error, urllib.parse, urllib.request, zipfile

STATE = os.path.expanduser('~/.local/state/ra-lab')
SIZE = 65536
CHUNK = 3 << 20


def state_dir():
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    os.chmod(STATE, 0o700)
    return STATE


def write_state(pc, d):
    p = os.path.join(state_dir(), pc + '.json')
    fd = os.open(p + '.tmp', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(d, f)
    os.replace(p + '.tmp', p)


def read_state(pc=None):
    files = [os.path.join(state_dir(), pc + '.json')] if pc else sorted(glob.glob(os.path.join(state_dir(), '*.json')), key=os.path.getmtime)
    if not files or not os.path.exists(files[-1]):
        sys.exit('ra-lab: ПК не подключался (нет %s)' % (pc or 'состояния'))
    with open(files[-1]) as f:
        d = json.load(f)
    d['pc'] = os.path.basename(files[-1])[:-5]
    return d


def call(st, method, path, body=None, raw=None, headers=None, timeout=None):
    """-> (код, объект). Агент ПК за ssh -R: 127.0.0.1:<port>."""
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    h = {'Authorization': 'Bearer ' + st['token']}
    h.update(headers or {})
    if body is not None:
        h['Content-Type'] = 'application/json'
    req = urllib.request.Request('http://127.0.0.1:%d%s' % (st['port'], path), data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode('utf-8') or '{}')
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode('utf-8'))
        except ValueError:
            return e.code, {}
    except (urllib.error.URLError, OSError) as e:
        sys.exit('ra-lab: канала нет (%s)' % getattr(e, 'reason', e))


def ok(st, method, path, body=None, **kw):
    code, obj = call(st, method, path, body, **kw)
    if code != 200:
        sys.exit('ra-lab: агент ответил %d: %s' % (code, obj.get('error') or obj))
    return obj


def notify(pc, version, rollback):
    for name in (pc, '_any'):
        s = socket.socket(socket.AF_UNIX)
        try:
            s.connect(os.path.join(state_dir(), name + '.events'))
            s.sendall(('UP\t%s\t%s\n' % (version, rollback or '-')).encode())
        except OSError:
            pass  # слушателя нет
        finally:
            s.close()


# --- session: проба 64 КиБ и канал ---
def cmd_session(a):
    out, inp = sys.stdout.buffer, sys.stdin.buffer
    data = os.urandom(SIZE)
    out.write(b'RALAB-PROBE1 %s %d\n' % (a.nonce.encode(), SIZE) + data + b'\nSHA256 %s\n' % hashlib.sha256(data).hexdigest().encode())
    out.flush()
    got = inp.read(SIZE)
    if len(got) < SIZE:
        return 0
    out.write(b'RALAB-UP1 %s %s\n' % (a.nonce.encode(), hashlib.sha256(got).hexdigest().encode()))
    out.flush()
    if inp.readline().strip() != b'CLAIM':  # BYE или EOF: тихий выход
        return 0
    token = inp.readline().strip().decode()
    st = {'port': a.port, 'token': token, 'version': a.version, 'rollback': a.rollback or '', 'pid': os.getpid()}
    write_state(a.pc, st)
    try:
        code = call(st, 'GET', '/status', timeout=20)[0]
    except SystemExit:
        code = 0
    if code != 200:
        out.write(b'RALAB-AGENT-FAIL %d\n' % code)
        out.flush()
        return 1
    out.write(b'RALAB-CHANNEL-UP %s\n' % a.version.encode())
    out.flush()
    notify(a.pc, a.version, a.rollback)
    while inp.read(4096):  # держим сессию до EOF (ПК закрыл ssh)
        pass
    try:
        if read_state(a.pc)['token'] == token:
            os.remove(os.path.join(STATE, a.pc + '.json'))
    except (SystemExit, OSError, ValueError):
        pass
    return 0


# --- ожидание ---
def listen(pc):
    p = os.path.join(state_dir(), (pc or '_any') + '.events')
    if os.path.exists(p):
        os.remove(p)
    s = socket.socket(socket.AF_UNIX)
    s.bind(p)
    s.listen(4)
    return s, p


def wait_notice(srv, path, deadline):
    srv.settimeout(deadline)  # срок - удобство ассистента на сервере, ПК он не касается
    try:
        c, _ = srv.accept()
        parts = c.recv(512).decode().strip().split('\t')
        c.close()
        return parts[1], (parts[2] if len(parts) > 2 and parts[2] != '-' else '')
    except socket.timeout:
        return None
    finally:
        srv.close()
        try:
            os.remove(path)
        except OSError:
            pass


def say_up(version, rollback, expect=None):
    print('подключён, версия %s%s%s' % (version, ' (ожидали %s)' % expect if expect and expect != version else '', ', откат: ' + rollback if rollback else ''))


def cmd_wait_up(a):
    srv, p = listen(a.pc)
    try:  # слушатель поднят до проверки: сообщение не потеряется
        st = read_state(a.pc)
        if call(st, 'GET', '/status', timeout=10)[0] == 200:
            srv.close()
            os.remove(p)
            return say_up(st['version'], st.get('rollback')) or 0
    except (SystemExit, OSError, ValueError):
        pass
    r = wait_notice(srv, p, a.deadline)
    if not r:
        sys.exit('ra-lab: за %d с ПК не подключился' % a.deadline)
    say_up(*r)


# --- команды ассистента ---
def cmd_status(a):
    print(json.dumps(ok(read_state(a.pc), 'GET', '/status'), ensure_ascii=False, indent=2))


def cmd_log(a):
    for r in ok(read_state(a.pc), 'GET', '/log?n=%d' % a.n)['records']:
        print('%s [%s] %s %s%s' % (r['ts'], r['src'], r['ev'], json.dumps(r.get('data'), ensure_ascii=False) if 'data' in r else '', '  -- ' + r['why'] if r.get('why') else ''))


def cmd_rank(a):
    r = ok(read_state(a.pc), 'GET', '/status')['rounds']
    print('раунд %s, канал: %s' % (r['round'], (r['channel'] or {}).get('path', 'нет')))
    for x in r['ranking']:
        print('%-28s %-8s вниз %6s КиБ/с вверх %6s КиБ/с задержка %5s с delay %5s мс  байт вниз %7s  %s' % (
            x['path'], x['outcome'], round((x.get('down_bps') or x.get('rate_bps') or 0) / 1024, 1), round((x.get('up_bps') or 0) / 1024, 1),
            x.get('latency_s'), x.get('delay_ms'), x.get('bytes_down'), x.get('reason') or ''))


def cmd_exec(a):
    st = read_state(a.pc)
    eid = ok(st, 'POST', '/exec', {'cmd': a.cmd, 'shell': a.shell, 'cwd': a.cwd})['id']
    t = None
    if a.max_time:
        t = threading.Timer(a.max_time, lambda: call(st, 'POST', '/kill', {'id': eid}))
        t.daemon = True
        t.start()
    dec = {'out': codecs.getincrementaldecoder('utf-8')('replace'), 'err': codecs.getincrementaldecoder('utf-8')('replace')}
    oo = eo = 0
    while True:  # длинный опрос: ответ приходит, когда есть новый вывод или процесс вышел
        r = ok(st, 'GET', '/proc?id=%s&out=%d&err=%d&wait=1' % (eid, oo, eo))
        oo, eo = r['out_off'], r['err_off']
        sys.stdout.write(dec['out'].decode(base64.b64decode(r['out_b64'])))
        sys.stderr.write(dec['err'].decode(base64.b64decode(r['err_b64'])))
        sys.stdout.flush()
        sys.stderr.flush()
        if r['exited']:
            break
    t and t.cancel()
    if r.get('truncated'):
        print('ra-lab: вывод урезан до последнего 1 МБ на поток', file=sys.stderr)
    return r['code'] if isinstance(r.get('code'), int) else 1


def cmd_kill(a):
    ok(read_state(a.pc), 'POST', '/kill', {'id': a.id})
    print('остановлен')


def cmd_read(a):
    st, off = read_state(a.pc), 0
    f = open(a.local, 'wb') if a.local else sys.stdout.buffer
    while True:
        r = ok(st, 'GET', '/read?path=%s&offset=%d' % (urllib.parse.quote(a.remote, safe=''), off))
        b = base64.b64decode(r['b64'])
        f.write(b)
        off += len(b)
        if r['eof'] or not b:
            break
    f.flush()


def cmd_write(a):
    st, off = read_state(a.pc), 0
    f = sys.stdin.buffer if a.local == '-' else open(a.local, 'rb')
    cur = f.read(CHUNK)
    while True:
        nxt = f.read(CHUNK) if cur else b''
        ok(st, 'POST', '/write', {'path': a.remote, 'b64': base64.b64encode(cur).decode(), 'offset': off, 'done': not nxt})
        off += len(cur)
        if not nxt:
            break
        cur = nxt
    print('записано %d байт' % off)


def cmd_restart(a):
    ok(read_state(a.pc), 'POST', '/restart', {})
    print('перезапуск Python запрошен')


def cmd_switch(a):
    ok(read_state(a.pc), 'POST', '/switch', {'path': a.path})
    print('переключение на %s запрошено' % a.path)


def cmd_push(a):
    here = os.getcwd()
    try:
        root = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], cwd=here).decode().strip()
    except (OSError, subprocess.CalledProcessError):
        sys.exit('ra-lab push: запускайте внутри git-каталога с lab/')
    lab = os.path.join(root, 'lab') if os.path.isdir(os.path.join(root, 'lab', 'ralab')) else here
    sha = subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], cwd=root).decode().strip()
    dirty = subprocess.check_output(['git', 'status', '--porcelain', '--', lab], cwd=root).decode().strip()
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        z.write(os.path.join(lab, 'run_lab.py'), 'run_lab.py')
        for p in sorted(glob.glob(os.path.join(lab, 'ralab', '**', '*.py'), recursive=True)):
            z.write(p, os.path.relpath(p, lab).replace(os.sep, '/'))
        z.writestr('code-version.txt', sha + ('-dirty' if dirty else '') + '\n')
    data = buf.getvalue()
    st = read_state(a.pc)
    srv = path = None
    if a.wait:
        srv, path = listen(a.pc)  # слушатель до отправки: сообщение о подъёме не потеряется
    code, r = call(st, 'POST', '/code', raw=data, headers={'X-Sha256': hashlib.sha256(data).hexdigest(), 'Content-Type': 'application/zip'})
    if code != 200:
        if srv:
            srv.close()
            os.remove(path)
        print('код отклонён:\n  ' + '\n  '.join(r.get('errors') or [r.get('error', str(code))]))
        return 1
    print('код принят: %s (%d файлов), Python перезапускается' % (r['dir'], r['files']))
    mark(st['pc'], 'push', {'dir': r['dir'], 'git': sha + ('-dirty' if dirty else ''), 'files': r['files']})
    if a.wait:
        n = wait_notice(srv, path, a.deadline)
        if not n:
            sys.exit('ra-lab: за %d с новая версия не подняла канал' % a.deadline)
        say_up(n[0], n[1], expect=r['dir'])


def logs_dir(pc):
    d = os.path.expanduser('~/work/logs-in/lab/%s' % pc)
    os.makedirs(d, exist_ok=True)
    return d


def mark(pc, ev, data):
    """Веха: что и когда выложено/случилось, одна строка JSON в ~/work/logs-in/lab/<ПК>/milestones.jsonl."""
    rec = {'ts': datetime.datetime.now().astimezone().isoformat(timespec='seconds'), 'ev': ev}
    rec.update(data)
    with open(os.path.join(logs_dir(pc), 'milestones.jsonl'), 'a', encoding='utf-8') as f:
        f.write(json.dumps(rec, ensure_ascii=False) + '\n')


def collect_once(pc, st):
    """Дочитывает новые байты журнала ПК. Файл стал меньше записанного - старую копию откладываем (.old-<время>)."""
    home = ok(st, 'GET', '/status').get('home')
    if not home:
        return 0
    logs = home + '\\logs'
    d, offp = logs_dir(pc), os.path.join(logs_dir(pc), '.offsets.json')
    offs = json.load(open(offp)) if os.path.exists(offp) else {}
    got = 0
    for e in ok(st, 'GET', '/files?path=' + urllib.parse.quote(logs, safe='')).get('entries', []):
        n = e['name']
        if e['dir'] or not n.startswith('lab-') or e.get('size') is None:
            continue
        local = os.path.join(d, n)
        if e['size'] < offs.get(n, 0):  # новый запуск перезаписал файл
            if os.path.exists(local):
                os.replace(local, local + '.old-' + str(int(time.time())))
            offs[n] = 0
        while offs.get(n, 0) < e['size']:
            r = ok(st, 'GET', '/read?path=%s&offset=%d' % (urllib.parse.quote(logs + '\\' + n, safe=''), offs.get(n, 0)))
            b = base64.b64decode(r['b64'])
            if not b:
                break
            with open(local, 'ab') as f:
                f.write(b)
            offs[n] = offs.get(n, 0) + len(b)
            got += len(b)
        json.dump(offs, open(offp, 'w'))
    return got


def cmd_collect(a):
    last_version = None
    while True:
        try:
            st = read_state(a.pc)
            if st.get('version') != last_version:
                mark(st['pc'], 'version', {'version': st.get('version'), 'rollback': st.get('rollback')})
                last_version = st.get('version')
            collect_once(st['pc'], st)
        except SystemExit:
            pass  # канала нет: ПК закрыт или переключается - повторим
        except Exception as e:
            print('collect: %s' % e, file=sys.stderr, flush=True)
        time.sleep(a.every)


def main():
    ap = argparse.ArgumentParser(prog='ra-lab', description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--pc', help='имя ПК (по умолчанию последний подключавшийся)')
    sub = ap.add_subparsers(dest='cmd', required=True)

    def add(name, fn, *args):
        p = sub.add_parser(name)
        for a_ in args:
            p.add_argument(*a_[0], **a_[1])
        p.set_defaults(fn=fn)
    P = lambda *n, **k: (n, k)
    add('session', cmd_session, P('--pc', dest='pc', required=True), P('--nonce', required=True), P('--port', type=int, required=True), P('--version', required=True), P('--rollback'))
    add('wait-up', cmd_wait_up, P('--deadline', type=int, default=90))
    add('status', cmd_status)
    add('log', cmd_log, P('-n', type=int, default=200))
    add('rank', cmd_rank)
    add('exec', cmd_exec, P('cmd', metavar='команда'), P('--shell', choices=['powershell', 'cmd'], default='powershell'), P('--max-time', type=float), P('--cwd'))
    add('kill', cmd_kill, P('id'))
    add('read', cmd_read, P('remote'), P('local', nargs='?'))
    add('write', cmd_write, P('remote'), P('local'))
    add('restart', cmd_restart)
    add('switch', cmd_switch, P('path'))
    add('collect', cmd_collect, P('--every', type=int, default=20))
    add('push', cmd_push, P('--wait', action='store_true'), P('--deadline', type=int, default=90))
    a = ap.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == '__main__':
    main()
