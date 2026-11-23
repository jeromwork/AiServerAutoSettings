"""Чтение настоящего конфига установленной RemoteAgents (раздел 2.9) - только чтение, своего формата нет.

Источник: %LOCALAPPDATA%\\RemoteAgents (config.json, профиль SSH, channel, secrets\\entries). Если есть
%LOCALAPPDATA%\\RemoteAgents-lab\\config.json (тот же формат), его разделы главнее, недостающие берутся из установленной.
known_hosts разбирается своим кодом (без внешних утилит): путь с пробелами и хешированные имена не проблема.
"""
import base64, fnmatch, glob, hashlib, hmac, json, os, re, shutil, types

from . import journal
from .bus import bus

LAN_MAX = 64
KNOWN_HOSTS_MAX = 4 * 1024 * 1024


class Fail(Exception):
    pass


def read_json(path):
    try:
        with open(path, encoding='utf-8-sig') as f:  # PowerShell пишет BOM
            return json.load(f)
    except (OSError, ValueError) as e:
        raise Fail('не прочитать JSON %s (%s)' % (os.path.basename(str(path)), e.__class__.__name__))


def _host_match(field, name):
    """Поле hosts строки known_hosts: список через запятую с * ? и !, либо хеш |1|соль|хеш."""
    if field.startswith('|1|'):
        parts = field.split('|')
        try:
            salt = base64.b64decode(parts[2])
            return hmac.compare_digest(base64.b64encode(hmac.new(salt, name.encode(), hashlib.sha1).digest()).decode(), parts[3])
        except (IndexError, ValueError):
            return False
    ok = False
    for pat in field.split(','):
        neg = pat.startswith('!')
        if fnmatch.fnmatchcase(name.lower(), pat.lstrip('!').lower()):
            if neg:
                return False
            ok = True
    return ok


def known_host_keys(path, host, port=22):
    """Ключи хоста из known_hosts: строки 'тип base64'. @revoked/@cert-authority и комментарии пропускаются, BOM и \\r снимаются."""
    name = host if int(port) == 22 else '[%s]:%d' % (host, int(port))
    try:
        with open(path, 'rb') as f:
            text = f.read(KNOWN_HOSTS_MAX).decode('utf-8-sig', 'replace').replace('\r', '')
    except OSError:
        return []
    keys = []
    for line in text.split('\n')[:20000]:
        parts = line.strip().split()
        if len(parts) < 3 or parts[0].startswith(('#', '@')):
            continue
        if parts[1].startswith(('ssh-', 'ecdsa-')) and _host_match(parts[0], name) and parts[1] + ' ' + parts[2] not in keys:
            keys.append(parts[1] + ' ' + parts[2])
    return keys


def server_port(prof):
    """Порт SSH сервера: аргумент -p профиля, иначе 22 (как Get-TransportServerPort)."""
    a = [str(x) for x in prof.get('arguments') or []]
    try:
        return int(a[a.index('-p') + 1])
    except (ValueError, IndexError):
        return 22


def find_ssh(installed, prof):
    c = [prof.get('sshExecutable'), os.path.join(installed, 'transport-bin', 'openssh', 'ssh.exe')]
    c += sorted(glob.glob(os.path.join(installed, 'bundle', '*', 'transport', 'ssh.exe')), reverse=True)
    c += [os.path.join(os.environ.get('SystemRoot') or r'C:\Windows', 'System32', 'OpenSSH', 'ssh.exe')]
    found = next((p for p in c if p and os.path.isfile(p)), None) or shutil.which('ssh')
    if not found:
        raise Fail('ssh не найден (профиль, bundle, System32\\OpenSSH)')
    return found


def find_singbox(installed, cfg):
    home = installed or ''  # порядок как в Ensure-WizardTransportBinary / lan_poc.find_singbox
    c = [(cfg.get('transport') or {}).get('singBoxPath'), os.path.join(home, 'transport-bin', 'sing-box.exe')]
    c += sorted(glob.glob(os.path.join(home, 'bundle', '*', 'transport', 'sing-box.exe')), reverse=True)
    found = next((p for p in c if p and os.path.isfile(p)), None) or shutil.which('sing-box')
    if not found:
        raise Fail('sing-box не найден')
    return found


def _merge(base, over):
    """Разделы lab-конфига главнее: словари - на один уровень вглубь, остальное заменяется целиком."""
    out = dict(base)
    for k, v in over.items():
        out[k] = dict(out[k], **v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def _lans(cfg):
    items = cfg.get('lan')
    if items is None:
        items = (cfg.get('profile') or {}).get('lan')  # так config.json хранит lan (Get-TransportLan читает profile.lan)
    out, seen = [], set()
    for it in (items if isinstance(items, list) else []):
        if not isinstance(it, dict) or not it.get('name') or it['name'] in seen:
            continue
        seen.add(it['name'])
        share = it.get('share') if isinstance(it.get('share'), dict) else {}
        host = str(it.get('testHost') or it.get('host') or '')
        port = it.get('testPort') or it.get('port') or 22
        if share.get('enabled') is False or not host or not isinstance(port, int) or not 0 < port < 65536:
            continue
        out.append({'name': str(it['name']), 'host': host, 'port': port, 'subnets': share.get('subnets') or [], 'domains': share.get('domains') or []})
    return out[:LAN_MAX]


def load(lab_home, installed):
    """-> SimpleNamespace(cfg, prof, outs, ssh, singbox, paths, skipped, lans, server, login, key, known_hosts, port)."""
    from . import paths as pth
    inst, lab = os.path.join(installed, 'config.json'), os.path.join(lab_home, 'config.json')
    cfg = read_json(inst) if os.path.isfile(inst) else {}
    if os.path.isfile(lab):
        cfg = _merge(cfg, read_json(lab))
        journal.log('settings', 'lab.config', {'file': lab}, 'найден config.json лаборатории: его разделы главнее установленной программы')
    t = cfg.get('transport') or {}
    if not t.get('profilePath'):
        raise Fail('нет transport.profilePath: установленная RemoteAgents не настроена (%s)' % inst)
    prof = read_json(t['profilePath'])
    for k in ('serverAddress', 'login', 'keyPath', 'knownHostsPath'):
        if not prof.get(k):
            raise Fail('в SSH-профиле нет поля %s' % k)
    try:
        outs = list(read_json(t['channelPath']).get('outbounds') or []) if t.get('channelPath') else []
    except Fail as e:
        outs = []
        journal.log('settings', 'channel.missing', {'reason': str(e)}, 'без channel пути relay/hop недоступны, узлы входа работают')
    journal.collect(outs)
    s = types.SimpleNamespace(cfg=cfg, prof=prof, outs=outs, installed=installed, server=prof['serverAddress'], login=prof['login'],
                              key=prof['keyPath'], known_hosts=prof['knownHostsPath'], port=server_port(prof))
    s.ssh, s.singbox = find_ssh(installed, prof), find_singbox(installed, cfg)
    s.paths, s.skipped = pth.build_paths(s)
    s.lans = _lans(cfg)
    return s


class Settings:
    """Часть «settings»: по app.start читает конфиг -> settings.loaded / settings.failed."""

    def __init__(self, ctx):
        self.ctx, self.loaded = ctx, False
        bus.subscribe('app.start', self._on_start)
        bus.subscribe('net.changed', self._on_net)
        bus.subscribe('channel.down', self._on_down)

    def _on_down(self, ev):  # канал оборвался: если VPN за это время сменился - применить сейчас
        if not ev.get('restart') and self.loaded:
            self._on_net(None)

    def _on_start(self, _):
        self._load()

    def _on_net(self, _):  # конфиг не прочитан (установленная программа ещё не настроена) - после смены сети пробуем снова
        if not self.loaded:
            self._load()
            return
        from . import paths as pth
        st = self.ctx.settings
        vpn, old = (pth.vpn_iface(), pth.local_proxies(st.cfg)), (getattr(st, 'vpn', None), getattr(st, 'proxies', []))
        if vpn != old:  # VPN включили/выключили: пути «через VPN» меняются. При живом канале держимся его (решение владельца)
            if getattr(self.ctx.rounds, 'channel', None):
                journal.log('settings', 'vpn.changed', {'from': old, 'to': vpn}, 'VPN изменился, канал жив: пути обновятся после обрыва')
                return
            journal.log('settings', 'vpn.changed', {'from': old, 'to': vpn}, 'VPN изменился: перечитываю пути и перезапускаю sing-box')
            self._load()

    def _load(self):
        try:
            self.ctx.settings = load(self.ctx.home, self.ctx.installed)
        except Exception as e:  # Fail - понятная причина; остальное (битый тип поля и т.п.) - имя ошибки
            bus.publish('settings.failed', {'reason': str(e) if isinstance(e, Fail) else 'ошибка настроек: %s' % e.__class__.__name__})
            return
        self.loaded = True
        s = self.ctx.settings
        bus.publish('settings.loaded', {'paths': [p['name'] for p in s.paths], 'lans': [n['name'] for n in s.lans], 'skipped': s.skipped,
                                        'ssh': s.ssh, 'singbox': s.singbox, 'server': s.server})
