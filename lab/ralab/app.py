"""Сборка частей, запуск, выход. Коды выхода Python: 0 - остановка (exit/EOF stdin), 3 - перезапуск (если есть code\\pending.json -
новая версия кода), 4 - память выше 300 МБ, любой другой - падение.
Аргументы: --home <...\\RemoteAgents-lab> --exe-version <v> [--rollback-reason <ascii <=160>] [--installed <папка установленной программы>].
"""
import argparse, os, re, socket, sys, threading, time, traceback, types

from . import journal, procs
from .bus import bus, rss_bytes

MEM_MAX = 300 * 1024 * 1024


class Ctx(types.SimpleNamespace):
    def status(self):
        s = getattr(self, 'settings', None)
        return {'home': self.home, 'version': self.version, 'exe_version': self.exe_version, 'rollback': self.rollback, 'computer': self.computer,
                'uptime_s': int(time.monotonic() - self.t0), 'rss_mb': round(rss_bytes() / 1048576, 1), 'events': bus.count,
                'agent_port': self.agent.port, 'color': self.link.color, 'state': self.link.note,
                'settings': {'paths': [p['name'] for p in s.paths], 'skipped': s.skipped, 'lans': [n['name'] for n in s.lans], 'server': s.server} if s else None,
                'singbox': self.singbox.status(), 'rounds': self.rounds.status(), 'lan': self.lan.status(), 'forward': self.forward.status(), 'tun': self.tun.status(), 'procs': procs.names()}

    def report(self):
        st = self.status()
        out = ['RemoteAgents-Lab: код %s, EXE %s, компьютер %s, работает %d с, память %s МБ, событий %d' % (
            st['version'], st['exe_version'], st['computer'], st['uptime_s'], st['rss_mb'], st['events'])]
        if st['rollback']:
            out.append('Откат версии: ' + st['rollback'])
        out.append('Состояние: %s (%s)' % (st['state'], st['color']))
        out.append('Настройки: %s' % (st['settings'] and '%d путей, %d сетей, пропущено: %s' % (len(st['settings']['paths']), len(st['settings']['lans']), st['settings']['skipped'])))
        out.append('sing-box: %s' % st['singbox'])
        r = st['rounds']
        out.append('Канал: %s' % (r['channel'] or 'нет') + ' (раунд %d)' % r['round'])
        out.append('Рейтинг последнего раунда:')
        out += ['  %s' % x for x in r['ranking']]
        out.append('Проброс: %s' % st['forward'])
        out.append('Сети:')
        out += ['  %s' % x for x in st['lan']]
        out.append('Последние 200 записей журнала:')
        out += ['%s [%s] %s %s %s' % (x['ts'], x['src'], x['ev'], x.get('data', ''), x.get('why', '')) for x in journal.tail(200)]
        return '\n'.join(out)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--home', required=True)
    ap.add_argument('--exe-version', default='')
    ap.add_argument('--rollback-reason', default='')
    ap.add_argument('--installed')
    a = ap.parse_args(argv)
    home = os.path.abspath(a.home)
    code_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # <home>\code\<имя>\ : версия кода = имя папки
    ctx = Ctx(home=home, installed=a.installed or os.path.join(os.path.dirname(home), 'RemoteAgents'), exe_version=a.exe_version,
              rollback=re.sub(r'[^\x20-\x7e]', '?', a.rollback_reason)[:160], version=os.path.basename(code_dir), settings=None,
              computer=re.sub(r'[^A-Za-z0-9_-]', '_', os.environ.get('COMPUTERNAME') or socket.gethostname())[:40], t0=time.monotonic(), exit_code=None)
    for d in ('logs', 'state', 'code', 'undo', 'private'):
        os.makedirs(os.path.join(home, d), exist_ok=True)
    journal.init(os.path.join(home, 'logs'))

    def crash(kind, text):
        journal.log('app', 'crash', {'kind': kind, 'trace': text[-1500:]})
        print(journal.mask(text[-800:]), file=sys.stderr)  # stderr уходит в exe.log без маскировки EXE: маскируем здесь
    sys.excepthook = lambda t, v, tb: crash('main', ''.join(traceback.format_exception(t, v, tb)))
    threading.excepthook = lambda args: crash('thread', ''.join(traceback.format_exception(args.exc_type, args.exc_value, args.exc_traceback)))

    from .link import Link
    from .settings import Settings
    from .singbox import SingBox
    from .agent import Agent
    from .rounds import Rounds
    from .lan import Lan
    from .forward import Forward
    from .tun import Tun
    from .netwatch import NetWatch
    from .updater import Updater
    ctx.agent, ctx.updater, ctx.singbox, ctx.netwatch = Agent(ctx), Updater(ctx), SingBox(ctx), NetWatch(ctx)
    ctx.settings_part, ctx.rounds, ctx.lan, ctx.forward = Settings(ctx), Rounds(ctx), Lan(ctx), Forward(ctx)
    ctx.tun = Tun(ctx)
    ctx.link = Link(ctx)
    done = threading.Event()

    def leave(code, why):
        if ctx.exit_code is None:
            ctx.exit_code = code
            journal.log('app', 'exit', {'code': code}, why)
            done.set()
    # app подписывается последним: к моменту его вызова остальные части уже отреагировали на app.stop
    bus.subscribe('app.stop', lambda ev: leave(0, 'остановка: %s' % ev.get('reason')))
    bus.subscribe('app.restart', lambda ev: leave(3, 'перезапуск: %s' % ev.get('why', '')))

    def memcheck():  # каждые 1000 событий
        rss = rss_bytes()
        if rss > MEM_MAX:
            leave(4, 'память %d МБ выше предела %d МБ: перезапуск' % (rss >> 20, MEM_MAX >> 20))
    bus.tick_hook = memcheck
    journal.log('app', 'start', {'version': ctx.version, 'exe_version': ctx.exe_version, 'rollback': ctx.rollback, 'home': home, 'pid': os.getpid()})
    bus.start()
    bus.publish('app.start')
    done.wait()  # выход - только событие (app.stop, app.restart, память)
    procs.kill_all()  # sing-box, ssh и команды агента (Job Object убьёт и тех, кого не успели)
    journal.flush()
    return ctx.exit_code
