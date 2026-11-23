"""Раунды измерений и канал (разделы 2.1-2.3): все пути пробуются одновременно, первый передавший 64 КиБ туда и обратно
становится каналом ассистента (его ssh-сессия не закрывается), остальные доводят замер и попадают в рейтинг.

Измерение и канал - одна ssh-сессия: ssh -R (обратный проброс к агенту ПК) + -D (SOCKS для проверки сетей) + команда ra-lab session.
Таймеров здесь нет, кроме guard('round.end', 60) в bus (Б). Замеры - чтение time.monotonic().
Протокол с сервером (ra_lab.py session): RALAB-PROBE1 <nonce> 65536 / 64 КиБ / SHA256 <hex> -> 64 КиБ от ПК -> RALAB-UP1 <nonce> <hex> ->
ПК пишет CLAIM + токен (победитель) или BYE -> RALAB-CHANNEL-UP <версия> | RALAB-AGENT-FAIL <код>.
"""
import collections, hashlib, json, os, re, secrets, threading, time

from . import journal, paths as pth, procs
from .bus import bus

SIZE = 65536
NODE_MAX = 3  # одновременных проб к одному узлу (по исследованию 2026 года частые TLS-подключения к узлу вызывают блокировку)
RPORTS = list(range(13340, 13400))
ROUND_SECONDS = 60
DEBOUNCE_SECONDS = 5  # владелец 23.11: после первого успешного пути ждать 5 с и взять лучший по скорости, а не первый (тот же единственный таймер round.end)
KNOWN = ('Permission denied', 'Host key verification failed', 'remote port forwarding failed', 'Connection refused', 'Connection reset',
         'Connection closed', 'Connection timed out', 'Could not resolve')
NULL = 'NUL' if os.name == 'nt' else '/dev/null'
OUTCOME_CLASS = {'ok': 0, 'frozen': 1, 'failed': 2, 'skipped': 3}


def fmt(x, d=1):
    return ('%.*f' % (d, x)).replace('.', ',')


def kib(bps):
    return fmt(bps / 1024) + ' КиБ/с'


def safe(text, n=80):
    return re.sub(r'[^A-Za-z0-9._-]', '_', str(text))[:n] or 'x'


class Probe:
    """Одна ssh-проба. feed() и on_err() работают в потоках-читателях и меняют только своё состояние; решения принимает rounds."""

    def __init__(self, rn, nonce, path, node, rport, socks):
        self.rn, self.nonce, self.path, self.node, self.rport, self.socks = rn, nonce, path, node, rport, socks
        self.name = 'ssh:%d:%s' % (rn, path)
        self.state, self.final = 'run', False  # run | ok | winner | failed | frozen | killed
        self.t0 = self.t1 = self.t2 = self.t3 = None
        self.rx = self.up = 0
        self.phase, self.buf, self.body = 0, bytearray(), 0
        self.sha, self.sent_hex, self.reason = hashlib.sha256(), None, ''
        self.stderr = collections.deque(maxlen=4)
        self.proc = None

    def _line(self, data, i):
        """Накопить байты до \\n; -> (строка|None, новый индекс). Строка не длиннее 256 байт."""
        j = data.find(b'\n', i)
        self.buf += data[i:j if j >= 0 else len(data)]
        if len(self.buf) > 256:
            raise ValueError('слишком длинная строка протокола')
        if j < 0:
            return None, len(data)
        line = self.buf.decode('ascii', 'replace').rstrip('\r')
        self.buf.clear()
        return line, j + 1

    def feed(self, data):
        if self.state not in ('run', 'winner', 'ok'):
            return
        self.rx += len(data)
        i = 0
        try:
            while i < len(data):
                if self.phase == 1:  # тело: сумма считается потоково, в памяти не копится
                    take = min(len(data) - i, SIZE - self.body)
                    self.sha.update(data[i:i + take])
                    self.body += take
                    i += take
                    if self.body == SIZE:
                        self.phase = 2
                    continue
                line, i = self._line(data, i)
                if line is None:
                    break
                self._on_line(line)
        except ValueError as e:
            self.fail(str(e))

    def _on_line(self, line):
        ph = self.phase
        if ph == 0:
            if line != 'RALAB-PROBE1 %s %d' % (self.nonce, SIZE):
                raise ValueError('неверный заголовок или nonce: ' + line[:40])
            self.t1, self.phase = time.monotonic(), 1
        elif ph == 2:
            if line != '':
                raise ValueError('нет разделителя перед SHA256')
            self.phase = 3
        elif ph == 3:
            if line != 'SHA256 ' + self.sha.hexdigest():
                raise ValueError('не сошлась контрольная сумма вниз')
            self.t2, self.phase = time.monotonic(), 4
            threading.Thread(target=self._upload, daemon=True).start()
        elif ph == 4:
            if line != 'RALAB-UP1 %s %s' % (self.nonce, self.sent_hex):
                raise ValueError('не сошлась контрольная сумма вверх')
            self.t3, self.phase, self.state = time.monotonic(), 5, 'ok'
            bus.publish('path.ok', {'name': self.name, 'path': self.path, 'round': self.rn,
                                    'latency': round(self.t1 - self.t0, 3), 'down_bps': round(SIZE / max(self.t2 - self.t1, 1e-6)),
                                    'up_bps': round(SIZE / max(self.t3 - self.t2, 1e-6)), 'down_s': round(self.t2 - self.t1, 3), 'up_s': round(self.t3 - self.t2, 3)})
        elif ph == 5:
            if line.startswith('RALAB-CHANNEL-UP') and self.state == 'winner':
                bus.publish('channel.up', {'name': self.name, 'path': self.path, 'rport': self.rport, 'socks': self.socks, 'server_version': line[17:60]})
            elif line.startswith('RALAB-AGENT-FAIL'):
                self.reason = 'агент ПК не ответил серверу: ' + line[:40]
                journal.log('rounds', 'agent.fail', {'path': self.path, 'line': line[:60]})

    def _upload(self):
        data = os.urandom(SIZE)
        self.sent_hex = hashlib.sha256(data).hexdigest()
        if self.proc and self.proc.write(data):
            self.up = SIZE

    def on_err(self, line):
        self.stderr.append(line[:160])

    def fail(self, reason):
        if self.state != 'run':
            return
        self.state, self.reason = 'failed', reason
        bus.publish('path.failed', {'name': self.name, 'path': self.path, 'round': self.rn, 'reason': reason, 'bytes_down': self.rx,
                                    'bytes_up': self.up, 'elapsed': round(time.monotonic() - self.t0, 3)})

    def exit_reason(self, code):
        tail = ' | '.join(self.stderr)
        for k in KNOWN:
            if k in tail:
                return '%s (ssh, код %s)' % (k, code)
        return (tail[-120:] if tail else 'ssh вышел, код %s' % code)


class Round:
    def __init__(self, rn, nonce, order, only):
        self.rn, self.nonce, self.only = rn, nonce, only
        self.queues, self.active = {}, collections.Counter()
        self.probes, self.rows, self.winner, self.finished, self.reason_started = [], {}, None, False, ''
        self.cands = []  # успешные пути, ждущие конца окна дебаунса: (проба, down_bps, событие)
        self.order = order


class Rounds:
    def __init__(self, ctx):
        self.ctx = ctx
        self.rn, self.round, self.channel, self.guard = 0, None, None, None
        self.sb_up, self.pending, self.rcur = False, None, 0
        self.live, self.probes = {}, {}  # live: все ssh-процессы (имя -> проба); probes: пробы текущего раунда
        self.ranking, self.dgen = [], 0
        self.rank_file = os.path.join(ctx.home, 'state', 'ranking.json')
        self.order = self._load_order()
        for t, f in (('singbox.started', self._on_sb_up), ('singbox.exited', self._on_sb_down), ('singbox.failed', self._on_sb_down),
                     ('agent.ready', self._on_agent), ('channel.up', self._on_channel_up), ('channel.down', self._on_channel_down),
                     ('net.changed', self._on_net), ('path.switch', self._on_switch), ('path.ok', self._on_ok), ('path.failed', self._on_failed),
                     ('proc.exited', self._on_exit), ('path.delay', self._on_delay), ('app.stop', self._on_stop)):
            bus.subscribe(t, f)
        self.stopping = False

    # --- состояние ---
    def _load_order(self):
        try:
            with open(self.rank_file, encoding='utf-8') as f:
                return [r['path'] for r in json.load(f).get('rows', [])][:64]
        except (OSError, ValueError, KeyError, TypeError):
            return []

    def _ready(self):
        return self.sb_up and bus.last('agent.ready') is not None and getattr(self.ctx, 'settings', None) is not None and not self.stopping

    def _on_stop(self, _):
        self.stopping = True

    def _on_sb_up(self, _):
        self.sb_up = True
        self._begin('sing-box запущен')

    def _on_sb_down(self, _):
        self.sb_up = False
        self.dgen += 1

    def _on_agent(self, _):
        if self.pending and self._ready():
            reason, only = self.pending
            self._begin(reason, only)

    def _on_net(self, _):
        try:
            if self.channel is None:
                self._begin('смена сети Windows, канала нет')
            else:
                journal.log('rounds', 'net.ignored', None, 'смена сети при живом канале: держимся текущего пути')
        finally:
            self.ctx.netwatch.ack()

    def _on_switch(self, ev):
        self._begin('команда ассистента: путь %s' % ev.get('path'), only=ev.get('path'))

    def _on_channel_up(self, ev):
        self.channel = ev
        journal.log('rounds', 'decision', None, 'канал поднят через %s (порт %d, SOCKS %d)' % (ev['path'], ev['rport'], ev['socks']))

    def _on_channel_down(self, ev):
        if ev.get('restart'):
            return
        self.channel = None
        self._begin('канал оборвался (%s): %s' % (ev.get('path'), ev.get('reason')))

    # --- раунд ---
    def _begin(self, reason, only=None):
        if not self._ready():
            self.pending = (reason, only)
            journal.log('rounds', 'round.deferred', {'reason': reason}, 'sing-box или агент ещё не готовы: раунд начнётся по событию')
            return
        self.pending = None
        s = self.ctx.settings
        if self.guard:
            self.guard.cancel()
        had_channel, self.dgen = self.channel, self.dgen + 1
        for p in list(self.live.values()):
            if p.state in ('run', 'ok', 'winner'):
                p.state = 'killed'
            if p.proc:
                p.proc.kill()
        if had_channel:
            self.channel = None
            bus.publish('channel.down', {'path': had_channel.get('path'), 'reason': 'новый раунд: ' + reason, 'restart': True})
        names = [p['name'] for p in s.paths]
        order = [n for n in self.order if n in names] + [n for n in names if n not in self.order]  # порядок прошлого рейтинга, остальные по конфигу
        if only:
            if only not in names:
                journal.log('rounds', 'switch.unknown', {'path': only}, 'такого пути нет, обычный раунд')
                only = None
            else:
                order = [only]
        self.rn += 1
        r = self.round = Round(self.rn, secrets.token_hex(8), order, only)
        self.probes = {}
        byname = {p['name']: p for p in s.paths}
        for n in order:
            r.queues.setdefault(byname[n]['node'], collections.deque()).append(n)
        # Б: у замёрзшего пути нет события «замёрз»; срок закрывает раунд и ограничивает частоту подключений к узлу
        self.guard = bus.guard('round.end', ROUND_SECONDS, lambda rn=self.rn: self._on_timer(rn))
        journal.log('rounds', 'round.begin', {'round': r.rn, 'paths': len(order), 'nodes': len(r.queues), 'only': only}, 'новый раунд: ' + reason)
        self._pump()

    def _alloc_rport(self):
        used = {p.rport for p in self.live.values()}
        for _ in RPORTS:
            port = RPORTS[self.rcur % len(RPORTS)]
            self.rcur += 1
            if port not in used:
                return port
        return None

    def _pump(self):
        r = self.round
        if not r or r.finished:
            return
        for node, q in r.queues.items():
            while q and r.active[node] < NODE_MAX:
                rport = self._alloc_rport()
                if rport is None:
                    return  # следующий порт освободится по событию выхода ssh
                self._launch(r, q.popleft(), node, rport)

    def _launch(self, r, path, node, rport):
        s, sb = self.ctx.settings, self.ctx.singbox
        p = Probe(r.rn, r.nonce, path, node, rport, pth.free_ports(1)[0])
        self.live[p.name] = self.probes[p.name] = p
        r.probes.append(p)
        r.active[node] += 1
        cmd = '~/.local/bin/ra-lab session --pc %s --nonce %s --port %d --version %s' % (safe(self.ctx.computer), r.nonce, rport, safe(self.ctx.version))
        if self.ctx.rollback:
            cmd += ' --rollback ' + safe(self.ctx.rollback, 160)
        argv = [s.ssh, '-T', '-F', NULL, '-p', str(sb.ports[path]), '-i', s.key, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                '-o', 'UserKnownHostsFile="%s"' % s.known_hosts.replace('\\', '/'), '-o', 'GlobalKnownHostsFile=none',
                '-o', 'StrictHostKeyChecking=yes', '-o', 'HostKeyAlias=' + s.server, '-o', 'ProxyCommand=none', '-o', 'ProxyJump=none',
                '-o', 'ConnectionAttempts=1', '-o', 'LogLevel=ERROR', '-o', 'ExitOnForwardFailure=yes',
                '-o', 'ServerAliveInterval=3', '-o', 'ServerAliveCountMax=3',  # детектор заморозки (23.11: 3 с x 3 = 9 с; шлёт пакет только когда канал молчит, ~3 МБ в сутки)
                '-R', '127.0.0.1:%d:127.0.0.1:%d' % (rport, self.ctx.agent.port), '-D', '127.0.0.1:%d' % p.socks,
                '%s@127.0.0.1' % s.login, cmd]
        p.t0 = time.monotonic()
        try:
            p.proc = procs.start(p.name, argv, src='ssh', binary=True, stdin=True, on_out=p.feed, on_err=p.on_err)
        except (OSError, ValueError) as e:
            p.fail('не запустить ssh: %s' % e.__class__.__name__)

    def _finalize(self, p, outcome):
        """Проба закончилась (событие или конец раунда): строка рейтинга, освобождение места на узле."""
        r = self.round
        p.final = True
        if r and p.rn == r.rn:
            r.active[p.node] = max(0, r.active[p.node] - 1)
            row = {'path': p.path, 'node': p.node, 'outcome': outcome, 'bytes_down': p.rx, 'bytes_up': p.up, 'reason': p.reason, 'delay_ms': None,
                   'latency_s': round(p.t1 - p.t0, 3) if p.t1 else None}
            if outcome == 'ok':
                row.update(down_bps=round(SIZE / max(p.t2 - p.t1, 1e-6)), up_bps=round(SIZE / max(p.t3 - p.t2, 1e-6)))
            elif outcome == 'frozen':
                el = max(time.monotonic() - p.t0, 1e-6)
                row.update(elapsed_s=round(el, 1), rate_bps=round(p.rx / el))
            else:
                row['elapsed_s'] = round(time.monotonic() - p.t0, 1)
            r.rows[p.path] = row

    def _on_ok(self, ev):
        p = self.probes.get(ev['name'])
        r = self.round
        if not p or p.final or not r or r.finished and r.winner:
            return
        self._finalize(p, 'ok')
        if r.winner is None and p.proc and p.proc.alive():
            # Дебаунс (владелец 23.11): первый успех не берём сразу - 5 с копим успешные пути (их ssh живут), затем _choose берёт самый быстрый.
            # TODO(владелец 23.11): переключение на более быстрый путь при работающем канале - решить позже (канал рвётся на секунды).
            r.cands.append((p, ev['down_bps'], ev))
            journal.log('rounds', 'decision', {'path': p.path, 'cands': len(r.cands)}, 'успех %s: %s вниз; кандидат, ждём %d с и берём лучшего' % (p.path, kib(ev['down_bps']), DEBOUNCE_SECONDS))
            if len(r.cands) == 1:
                if self.guard:
                    self.guard.cancel()
                self.guard = bus.guard('round.end', DEBOUNCE_SECONDS, lambda rn=self.rn: self._on_timer(rn))  # тот же единственный таймер, короче
        else:
            if p.proc:
                p.proc.write(b'BYE\n')  # «спасибо»: сервер тихо выходит; скорость уже записана в рейтинг
                p.proc.close_stdin()
            journal.log('rounds', 'decision', {'path': p.path}, '%s: 64 КиБ вниз %s, вверх %s - %s' % (
                p.path, kib(ev['down_bps']), kib(ev['up_bps']), 'не победил, готов позже первого' if r.winner else 'ssh уже вышел'))
        self._after_final()

    def _on_failed(self, ev):
        p = self.probes.get(ev['name'])
        if not p or p.final:
            return
        self._finalize(p, 'failed')
        journal.log('rounds', 'decision', {'path': p.path, 'bytes_down': p.rx}, 'отказ %s: %s (получено %d байт вниз, %d вверх)' % (p.path, p.reason, p.rx, p.up))
        if p.proc:
            p.proc.kill()
        self._after_final()

    def _on_exit(self, ev):
        p = self.live.pop(ev['name'], None)
        if not p:
            return
        if p.state in ('run', 'ok') and not p.final:
            p.state = 'run'
            p.fail('EOF на %d байт: %s' % (p.rx, p.exit_reason(ev['code'])))
        elif p.state == 'winner':
            bus.publish('channel.down', {'path': p.path, 'code': ev['code'], 'reason': p.exit_reason(ev['code']), 'was_up': bool(self.channel)})
        self._pump()  # освободился порт 13340-13399

    def _after_final(self):
        self._pump()
        r = self.round
        if r and not r.finished and all(p.final for p in r.probes) and not any(r.queues.values()):
            self._finish(False)

    def _on_timer(self, rn):
        r = self.round
        if not r or r.rn != rn:
            return
        if not r.finished:
            self._finish(True)
        elif r.winner is None:
            self._begin('нет победителя, срок раунда вышел')

    def _choose(self, r):
        """Конец окна дебаунса: победитель - самый быстрый из живых кандидатов, остальные получают BYE."""
        alive = [c for c in r.cands if c[0].proc and c[0].proc.alive()]
        r.cands = []
        if not alive:
            return
        best = max(alive, key=lambda c: c[1])
        for p, _, ev in alive:
            if p is best[0]:
                r.winner, p.state = p, 'winner'
                journal.log('rounds', 'decision', {'path': p.path}, 'победил %s из %d кандидатов: 64 КиБ вниз за %s с (%s), вверх %s с (%s), задержка %s с; держу канал' % (
                    p.path, len(alive), fmt(ev['down_s']), kib(ev['down_bps']), fmt(ev['up_s']), kib(ev['up_bps']), fmt(ev['latency'], 2)))
                p.proc.write(b'CLAIM\n' + self.ctx.agent.token.encode() + b'\n')  # токен только через stdin
            else:
                p.proc.write(b'BYE\n')
                p.proc.close_stdin()

    def _finish(self, timer):
        r = self.round
        if r.winner is None and r.cands:
            self._choose(r)
        r.finished = True
        now = time.monotonic()
        for p in r.probes:
            if not p.final and p.state in ('run', 'ok'):
                p.state = 'frozen'
                self._finalize(p, 'frozen')
            if p is not r.winner and p.proc and p.proc.alive():
                p.proc.kill()
        for q in r.queues.values():
            for n in q:
                r.rows[n] = {'path': n, 'node': '', 'outcome': 'skipped', 'bytes_down': 0, 'bytes_up': 0, 'reason': 'не успела стартовать (лимит на узел или порты)', 'delay_ms': None}
            q.clear()
        rows = sorted(r.rows.values(), key=lambda x: (OUTCOME_CLASS[x['outcome']], -(x.get('down_bps') or x.get('rate_bps') or 0)))[:64]
        self.ranking, self.order = rows, [x['path'] for x in rows]
        self._save(r)
        parts = []
        for x in rows:
            if x['outcome'] == 'ok':
                parts.append('%s %s' % (x['path'], kib(x['down_bps'])))
            elif x['outcome'] == 'frozen':
                parts.append('%s замёрз на %d байтах (%s за %s с)' % (x['path'], x['bytes_down'], kib(x['rate_bps']), fmt(x['elapsed_s'], 0)))
            else:
                parts.append('%s - %s' % (x['path'], x['reason'][:60] or x['outcome']))
        journal.log('rounds', 'ranking', {'round': r.rn, 'rows': rows}, 'рейтинг раунда %d (%s): %s' % (r.rn, 'по таймеру Б' if timer else 'все пробы завершились событиями', '; '.join(parts)))
        bus.publish('round.done', {'round': r.rn, 'winner': r.winner.path if r.winner else None, 'timer': timer})
        if r.winner:
            if self.guard:
                self.guard.cancel()
        elif timer or r.only:
            self._begin('нет победителя' + (' (путь ассистента не сработал, обычный раунд)' if r.only else ', срок раунда вышел'))
            return
        # раунд кончился раньше срока без победителя: следующий начнёт таймер Б (не чаще раза в 60 с на узел)
        self._start_delays(rows)

    def _save(self, r):
        try:
            os.makedirs(os.path.dirname(self.rank_file), exist_ok=True)
            tmp = self.rank_file + '.tmp'
            with open(tmp, 'w', encoding='utf-8') as f:
                json.dump({'round': r.rn, 'ts': time.strftime('%Y-%m-%dT%H:%M:%S'), 'rows': self.ranking}, f, ensure_ascii=False)
            os.replace(tmp, self.rank_file)
        except OSError as e:
            journal.log('rounds', 'ranking.save_failed', {'error': e.__class__.__name__})

    # --- delay sing-box (Clash API) после раунда: по узлам параллельно, внутри узла по одному; ответы - события ---
    def _start_delays(self, rows):
        gen, sb = self.dgen, self.ctx.singbox
        by = collections.defaultdict(list)
        for x in rows:
            if x['outcome'] != 'skipped':
                by[x['node']].append(x['path'])

        def worker(paths):
            for pth_ in paths:
                if gen != self.dgen or not self.sb_up:
                    return  # начался новый раунд или sing-box вышел
                ms, st = sb.delay(pth_)
                bus.publish('path.delay', {'path': pth_, 'ms': ms, 'status': st, 'gen': gen})
        for paths in by.values():
            threading.Thread(target=worker, args=(paths,), daemon=True).start()

    def _on_delay(self, ev):
        if ev['gen'] != self.dgen:
            return
        for x in self.ranking:
            if x['path'] == ev['path']:
                x['delay_ms'] = ev['ms']
        if self.round:
            self._save(self.round)

    def status(self):
        r = self.round
        return {'round': self.rn, 'sb_up': self.sb_up, 'channel': self.channel, 'finished': bool(r and r.finished), 'ranking': self.ranking,
                'probes': [{'path': p.path, 'state': p.state, 'rx': p.rx} for p in self.probes.values()][:64]}
