#!/usr/bin/env python3
"""ra-lab: серверная часть Лаборатории RemoteAgents (запускается на сервере 109 от пользователя remoteagents, без root).

  ra-lab session ...   служебная: её запускает ssh ПК (проба 64 КиБ и канал), руками не вызывается
  ra-lab wait-up [--deadline 90] [--pc ИМЯ]      ждать подключения ПК
  ra-lab status | log [-n N] | rank | exec "<cmd>" [--shell powershell|cmd] [--max-time S] [--cwd D] | kill <id> |
         read <удалённый путь> [локальный] | write <удалённый путь> <локальный|-> | restart | switch <путь> | vpn [off|auto|only] | push [--wait] |
         collect [--every 20]   (долгая: докачивает журнал ПК в ~/work/logs-in/lab/<ПК>/, живёт и после закрытия лаборатории)
  ra-lab expose <имя> <порт сервера> [--pc-port N]   открыть TCP-порт на localhost ПК; повтор меняет цель
  ra-lab unexpose <имя>                            снять проброс и удалить запись
  ra-lab autoforward                              служба devports-auto: сама выкладывает dev-серверы на все ПК, страница http://localhost:8199
  ra-lab ports                                    слушатели сервера и действующие пробросы ПК
  ra-lab free-port [--from 8200] [--to 8999]        выбрать и зарезервировать порт на 10 минут
Состояние: ~/.local/state/ra-lab/ (0700): <ПК>.json {port, token, version, rollback} (0600) и <ПК>.events (unix-сокет wait-up).
Реестры exposed.json [{name, serverPort, pcPort, cwd, ts}] и reserved.json [{port, expires}]: атомарно, 0600, под flock.
Токен агента никогда не печатается. Стандартная библиотека, Python 3.8+.
"""
import argparse, http.server, re, base64, codecs, contextlib, datetime, fcntl, glob, hashlib, io, json, os, socket, subprocess, sys, tempfile, threading, time, urllib.error, urllib.parse, urllib.request, zipfile

# Чёрный список автопроброса (не выкладывать): порты, части имени/командной строки процесса.
NO_AUTO_PORTS = [22, 53, 443, 1080, 2053, 3306, 5432, 8199, 8444, 9222, 47831, 55432, 8384, 22000, 21027,
                 range(13340, 13400),   # каналы Лаборатории
                 range(32768, 65536)]   # эфемерные порты (VS Code, happier, отладка и пр. — не dev-серверы)
NO_AUTO_PROCS = ['happier', 'chrome', 'chromium', 'syncthing', 'postgres', 'mysql', 'mariadb', 'sing-box', 'tailscale',
                 '.vscode-server', 'code-', 'antigravity', 'ra_lab', 'sshd', 'docker']
PAGE_PORT = 8199

STATE = os.path.expanduser('~/.local/state/ra-lab')
SIZE = 65536
CHUNK = 3 << 20
REGISTRIES = {'exposed.json', 'reserved.json'}


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
    files = [os.path.join(state_dir(), pc + '.json')] if pc else sorted(
        (p for p in glob.glob(os.path.join(state_dir(), '*.json')) if os.path.basename(p) not in REGISTRIES), key=os.path.getmtime)
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


def start_shim(pc, st):
    """MCP-шим windows_* (mcp_shim.py рядом): только у победителя CLAIM; любая ошибка шима сессию не роняет."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import mcp_shim
        def ag(method, path, body=None, timeout=15):
            try:
                return call(st, method, path, body, timeout=timeout)
            except SystemExit:
                return None, {}
        ident = mcp_shim.identity(pc)
        mcp_shim.register(pc, ident)
        shim = mcp_shim.Shim(ident, ag)
        shim.start()
        return shim
    except Exception as e:
        print('ra-lab: шим MCP не поднят: %s' % e.__class__.__name__, file=sys.stderr)
        return None


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
    shim = start_shim(a.pc, st)
    try:
        while inp.read(4096):  # держим сессию до EOF (ПК закрыл ssh)
            pass
    finally:
        try:
            shim and shim.close()
        except Exception:
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
@contextlib.contextmanager
def registry_lock():
    """Отдельный неизменяемый inode для flock: блокировка переживает os.replace JSON-файлов."""
    fd = os.open(os.path.join(state_dir(), 'ports.lock'), os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, 'a') as f:
        os.fchmod(f.fileno(), 0o600)
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def read_registry(name):
    try:
        with open(os.path.join(STATE, name), encoding='utf-8') as f:
            rows = json.load(f)
    except FileNotFoundError:
        return []
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise ValueError('%s: ожидался список записей' % name)
    for row in rows:
        if name == 'exposed.json':
            name_arg(row.get('name'))
            port_arg(row.get('serverPort'))
            port_arg(row.get('pcPort'))
        else:
            port_arg(row.get('port'))
            if not isinstance(row.get('expires'), (int, float)):
                raise ValueError('%s: нужен expires' % name)
    return rows


def write_registry(name, rows):
    fd, tmp = tempfile.mkstemp(prefix=name + '-', suffix='.tmp', dir=state_dir())
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            os.fchmod(f.fileno(), 0o600)
            json.dump(rows, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, os.path.join(STATE, name))
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def port_arg(value):
    try:
        port = int(value)
        if isinstance(value, bool) or str(port) != str(value) or not 1 <= port <= 65535:
            raise ValueError()
        return port
    except (ValueError, TypeError):
        raise argparse.ArgumentTypeError('порт должен быть целым числом от 1 до 65535')


def name_arg(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 128 or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise argparse.ArgumentTypeError('нужно непустое имя до 128 символов без управляющих символов')
    return value


def server_listeners():
    """ss: IPv4/IPv6, любой bind-адрес; процессы показываем, если текущий пользователь их видит."""
    try:
        out = subprocess.check_output(['ss', '-ltnHp'], text=True, stderr=subprocess.PIPE)
    except (OSError, subprocess.CalledProcessError) as e:
        raise OSError('не удалось получить слушателей сервера через ss') from e
    rows = []
    for line in out.splitlines():
        cols = line.split(None, 5)
        if len(cols) < 5:
            continue
        addr = cols[3]
        try:
            port = int(addr.rsplit(':', 1)[1])
        except (IndexError, ValueError):
            continue
        rows.append({'port': port, 'address': addr, 'process': cols[5] if len(cols) > 5 else '-'})
    return sorted(rows, key=lambda row: (row['port'], row['address']))


def pc_names():
    return sorted(os.path.basename(p)[:-5] for p in glob.glob(os.path.join(state_dir(), '*.json')) if os.path.basename(p) not in REGISTRIES)


def pc_online(only=None):
    """-> [(состояние ПК, [проброшенное на ПК])] для ПК, чей канал ответил за 3 с; остальные пропускаем с предупреждением."""
    res = []
    for pc in [only] if only else pc_names():
        try:
            st = read_state(pc)
            code, r = call(st, 'GET', '/exposed', timeout=3)
            if code != 200 or not r.get('channel', True):
                raise SystemExit('канал не готов')
            res.append((st, r['exposed']))
        except (SystemExit, OSError, ValueError, KeyError) as e:
            print('ra-lab: предупреждение: ПК %s недоступен (%s), пропущен' % (pc, e), file=sys.stderr)
    return res


def place(name, server_port, want, pcs):
    """Выложить name на все ПК одним номером порта: ПК вернул другой (занят) -> берём его и повторяем на всех. -> порт|None."""
    pcs = list(pcs)
    for _ in range(30):
        ports = []
        for st in list(pcs):
            try:
                ports.append(ok(st, 'POST', '/expose', {'name': name, 'serverPort': server_port, 'pcPort': want}, timeout=15)['pcPort'])
            except SystemExit as e:
                print('ra-lab: предупреждение: ПК %s: %s' % (st['pc'], e), file=sys.stderr)
                pcs.remove(st)
        if not ports:
            return None
        if set(ports) == {want}:
            return want
        want = max(ports)
    return None


def cmd_expose(a):
    """Открыть порт сервера на localhost ВСЕХ подключённых ПК (одним номером); сохранить имя и напечатать URL."""
    try:
        if a.server_port not in {row['port'] for row in server_listeners()}:
            print('ra-lab: предупреждение: порт %d на сервере пока не слушается' % a.server_port, file=sys.stderr)
    except OSError as e:
        print('ra-lab: предупреждение: %s' % e, file=sys.stderr)
    pcs = pc_online(a.pc)
    if not pcs:
        sys.exit('ra-lab: нет подключённых ПК')
    with registry_lock():
        rows = read_registry('exposed.json')
        old = next((row for row in rows if row['name'] == a.name), None)
        want = a.pc_port or (old['pcPort'] if old else a.server_port)
        port = place(a.name, a.server_port, want, [p[0] for p in pcs])
        if port is None:
            sys.exit('ra-lab: не удалось выложить %s' % a.name)
        record = {'name': a.name, 'serverPort': a.server_port, 'pcPort': port,
                  'cwd': os.getcwd(), 'ts': datetime.datetime.now().astimezone().isoformat(timespec='seconds')}
        write_registry('exposed.json', [row for row in rows if row['name'] != a.name] + [record])  # ручной: без auto
    print('http://localhost:%d' % port)


def unexpose_all(name, only=None):
    for st, _ in pc_online(only):
        try:
            call(st, 'POST', '/unexpose', {'name': name}, timeout=15)
        except SystemExit:
            pass


def cmd_unexpose(a):
    """Закрыть именованный проброс на всех подключённых ПК и удалить его из серверного реестра."""
    with registry_lock():
        rows = read_registry('exposed.json')
        unexpose_all(a.name, a.pc)
        write_registry('exposed.json', [row for row in rows if row['name'] != a.name])
    print('снят: %s' % a.name)


def cmd_ports(a):
    """Показать TCP-слушателей сервера; при доступном канале — имя, порт и состояние на ПК."""
    listeners = server_listeners()
    with registry_lock():
        registered = read_registry('exposed.json')
    remote = None
    try:
        code, r = call(read_state(a.pc), 'GET', '/exposed', timeout=5)
        if code == 200 and r.get('channel', True):
            remote = r['exposed']
    except (SystemExit, OSError, ValueError):
        pass
    if remote is None:
        print('ra-lab: нет канала; показаны порты сервера и сохранённые имена', file=sys.stderr)
    # ПК — источник истины для pcPort: после перезапуска он мог выбрать другой порт.
    by_name = {row['name']: row for row in registered}
    if remote is not None:
        by_name.update({row['name']: row for row in remote})
    live_names = {row['name']: row for row in remote or []}
    by_port = {}
    for row in by_name.values():
        by_port.setdefault(row['serverPort'], []).append(row)
    listening_ports = {row['port'] for row in listeners}
    listeners += [{'port': port, 'address': '(не слушает)', 'process': '-'} for port in by_port if port not in listening_ports]
    table = [['ПОРТ', 'АДРЕС', 'ПРОЦЕСС', 'ИМЯ'] + (['ПОРТ ПК', 'СТАТУС'] if remote is not None else [])]
    for row in sorted(listeners, key=lambda row: (row['port'], row['address'])):
        for entry in by_port.get(row['port']) or [None]:
            cells = [str(row['port']), row['address'], row['process'], entry['name'] if entry else '-']
            if remote is not None:
                live = live_names.get(entry['name']) if entry else None
                cells += [str(live['pcPort']) if live else '-',
                          ('на ПК слушает' if live.get('listening') else 'на ПК не слушает') if live else '-']
            table.append(cells)
    widths = [max(len(row[i]) for row in table) for i in range(len(table[0]))]
    for row in table:
        print('  '.join(cell.ljust(width) for cell, width in zip(row, widths)).rstrip())


def cmd_free_port(a):
    """Выдать первый свободный порт в диапазоне и атомарно зарезервировать его на 10 минут."""
    if a.port_from > a.port_to:
        sys.exit('ra-lab: --from должен быть не больше --to')
    with registry_lock():
        now = time.time()
        reserved = [row for row in read_registry('reserved.json') if row['expires'] > now]
        busy = {row['port'] for row in server_listeners()}
        busy.update(row['serverPort'] for row in read_registry('exposed.json'))
        busy.update(row['port'] for row in reserved)
        port = next((p for p in range(a.port_from, a.port_to + 1) if p not in busy), None)
        if port is None:
            sys.exit('ra-lab: нет свободного порта в диапазоне %d–%d' % (a.port_from, a.port_to))
        write_registry('reserved.json', reserved + [{'port': port, 'expires': now + 600}])
    print(port)


# --- автопроброс: dev-серверы сервера сразу на localhost всех ПК + страница-список ---
PAGE = {'rows': []}


def auto_candidates(blocked):
    """{порт: (имя, процесс)} для слушающих dev-серверов пользователя вне чёрного списка."""
    res = {}
    for row in server_listeners():
        host, port = row['address'].rsplit(':', 1)[0], row['port']
        m = re.search(r'\("([^"]+)",pid=(\d+)', row['process'])
        if host not in ('127.0.0.1', '0.0.0.0', '*', '[::]', '[::1]') or port < 1024 or port in blocked or not m:
            continue
        if any(port == b or (isinstance(b, range) and port in b) for b in NO_AUTO_PORTS):
            continue
        comm, pid = m.group(1), m.group(2)
        try:
            if os.stat('/proc/%s' % pid).st_uid != os.getuid():
                continue
            cmdline = open('/proc/%s/cmdline' % pid, 'rb').read().replace(b'\0', b' ').decode('utf-8', 'replace').lower()
            cwd = os.readlink('/proc/%s/cwd' % pid)
        except OSError:
            continue
        if any(x in comm.lower() or x in cmdline for x in NO_AUTO_PROCS):
            continue
        res.setdefault(port, ('%s-%d' % (os.path.basename(cwd.rstrip('/')) or comm, port), comm, cwd))
    return res


DOCKER = {'ts': 0.0, 'ports': {}}


def docker_ports():
    """{порт: контейнер} для docker-публикаций TCP на 127.0.0.1/0.0.0.0; не чаще раза в 2 с, при ошибке — пусто."""
    if time.time() - DOCKER['ts'] < 2:
        return DOCKER['ports']
    DOCKER['ts'] = time.time()
    res = {}
    try:
        out = subprocess.check_output(['sudo', '-n', 'docker', 'ps', '--format', '{{.Names}}\t{{.Ports}}'], text=True,
                                      stderr=subprocess.DEVNULL, timeout=10)
        for line in out.splitlines():
            name, _, ports = line.partition('\t')
            for host, port in re.findall(r'(127\.0\.0\.1|0\.0\.0\.0):(\d+)->\d+/tcp', ports):
                res.setdefault(int(port), name)
    except (OSError, subprocess.SubprocessError):
        pass
    DOCKER['ports'] = res
    return res


def autoforward_step(miss):
    pcs = pc_online()
    if not pcs:
        return
    sts = [p[0] for p in pcs]
    blocked = {st['port'] for st in sts}
    listening = {r['port']: r['process'] for r in server_listeners()}
    cand = auto_candidates(blocked)
    for port, cname in docker_ports().items():
        if port >= 1024 and port not in blocked and port not in cand and not any(port == b or (isinstance(b, range) and port in b) for b in NO_AUTO_PORTS):
            cand[port] = (cname, 'docker: ' + cname, '-')
    with registry_lock():
        rows = read_registry('exposed.json')
        known = {r['serverPort'] for r in rows}
        for port, (name, comm, cwd) in sorted(cand.items()):
            if port in known:
                continue
            if any(r['name'] == name for r in rows):
                name = '%s-%d' % (name, port)
            got = place(name, port, port, sts)
            if got:
                rows.append({'name': name, 'serverPort': port, 'pcPort': got, 'cwd': cwd, 'proc': comm, 'auto': True,
                             'ts': datetime.datetime.now().astimezone().isoformat(timespec='seconds')})
                print('autoforward: +%s -> localhost:%d' % (name, got), flush=True)
        if not any(r['name'] == 'devports' for r in rows):
            rows.append({'name': 'devports', 'serverPort': PAGE_PORT, 'pcPort': PAGE_PORT, 'cwd': STATE, 'proc': 'ra-lab autoforward'})
        keep = []
        for r in rows:
            if r.get('auto') and r['serverPort'] not in listening:
                miss[r['name']] = miss.get(r['name'], 0) + 1
                if miss[r['name']] >= 3:  # 3 проверки подряд (~6 с): порт ушёл
                    unexpose_all(r['name'])
                    print('autoforward: -%s' % r['name'], flush=True)
                    continue
            else:
                miss.pop(r['name'], None)
            keep.append(r)
        # ПК подключился позже / потерял проброс: догнать всё из реестра тем же портом
        for r in keep:
            for st, exp in pcs:
                have = {e['name']: e for e in exp}.get(r['name'])
                if not have or have['pcPort'] != r['pcPort'] or have['serverPort'] != r['serverPort']:
                    got = place(r['name'], r['serverPort'], r['pcPort'], sts)
                    if got:
                        r['pcPort'] = got
                    break
        write_registry('exposed.json', keep)
        PAGE['rows'] = [{'name': r['name'], 'port': r['pcPort'], 'proc': r.get('proc') or ('docker: ' + docker_ports()[r['serverPort']] if r['serverPort'] in docker_ports() else None) or ((re.search(r'"([^"]+)"', listening.get(r['serverPort']) or '') or [0, '-'])[1]),
                         'auto': bool(r.get('auto')), 'pcs': [st['pc'] for st, exp in pcs if any(e['name'] == r['name'] for e in exp)]}
                        for r in keep]


class PageHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        import html
        trs = ''.join('<tr><td>%s</td><td>%d</td><td><a href="http://localhost:%d">http://localhost:%d</a></td><td>%s</td><td>%s</td><td>%s</td></tr>' % (
            html.escape(r['name']), r['port'], r['port'], r['port'], html.escape(r['proc']), 'авто' if r['auto'] else 'вручную',
            html.escape(', '.join(r['pcs']) or '-')) for r in sorted(PAGE['rows'], key=lambda r: r['port']))
        body = ('<!doctype html><meta charset=utf-8><meta http-equiv=refresh content=5><title>devports</title>'
                '<style>body{font:14px sans-serif;margin:2em}td,th{padding:4px 12px;border-bottom:1px solid #ccc;text-align:left}</style>'
                '<h2>Dev-серверы на localhost</h2><table><tr><th>имя<th>порт<th>ссылка<th>процесс<th>как<th>открыто на ПК</tr>%s</table>' % trs).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def cmd_autoforward(a):
    """Служба: раз в ~2 с выкладывать новые dev-серверы на все ПК, снимать пропавшие; страница-список на 127.0.0.1:8199."""
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', PAGE_PORT), PageHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    miss = {}
    while True:
        try:
            autoforward_step(miss)
        except (SystemExit, Exception) as e:
            print('autoforward: ошибка: %s' % e, flush=True)
        time.sleep(a.every)


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


def cmd_vpn(a):
    st = read_state(a.pc)
    if a.mode:
        ok(st, 'POST', '/vpn', {'mode': a.mode})
        print('VPN: режим %s' % a.mode)
    code, r = call(st, 'GET', '/status')
    print(json.dumps((r or {}).get('vpn') if isinstance(r, dict) else r, ensure_ascii=False, indent=2))


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
        p = sub.add_parser(name, **({'help': fn.__doc__.splitlines()[0]} if fn.__doc__ else {}))
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
    add('vpn', cmd_vpn, P('mode', nargs='?', choices=['off', 'auto', 'only']))
    add('expose', cmd_expose, P('name', type=name_arg), P('server_port', type=port_arg), P('--pc-port', type=port_arg))
    add('unexpose', cmd_unexpose, P('name', type=name_arg))
    add('ports', cmd_ports)
    add('free-port', cmd_free_port, P('--from', dest='port_from', type=port_arg, default=8200), P('--to', dest='port_to', type=port_arg, default=8999))
    add('autoforward', cmd_autoforward, P('--every', type=float, default=2))
    add('collect', cmd_collect, P('--every', type=int, default=20))
    add('push', cmd_push, P('--wait', action='store_true'), P('--deadline', type=int, default=90))
    a = ap.parse_args()
    try:
        sys.exit(a.fn(a) or 0)
    except (OSError, ValueError, argparse.ArgumentTypeError) as e:
        sys.exit('ra-lab: %s' % e)


if __name__ == '__main__':
    main()
