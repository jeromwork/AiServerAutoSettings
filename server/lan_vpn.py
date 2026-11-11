#!/usr/bin/env python3
"""Restricted OpenVPN importer and transactional Linux LAN manager.

Python is used for structured parsing (inline secrets, JSON, CIDR and nft JSON),
not for implementing a VPN. All networking uses OpenVPN/iproute2/nft/systemd.
"""
import argparse
import contextlib
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

ETC = Path('/etc/remoteagents/lan')
STATE = Path('/var/lib/remoteagents/lan')
SB = Path('/etc/sing-box/config.json')
BIN = Path('/usr/local/lib/remoteagents/lan')
LOG = Path('/var/log/remoteagents/lan.log')
TABLE = 'remoteagents_lan'
# World-readable, secret-free status for the settings window (no sudo needed to read).
PUBLIC = Path('/var/lib/remoteagents-status')
# Every owner-confirmed network transaction; only one may wait for confirm at a time.
PENDING = (Path('/var/lib/remoteagents/lan/pending'), Path('/var/lib/remoteagents/port-leak/pending'),
           Path('/var/lib/remoteagents/proxy-out/pending'))
MARKER = '---remoteagents-stdin---'
PRIVATE = tuple(ipaddress.ip_network(s) for s in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'))
# OS interface name <= 15 bytes (tun-lan- is 8 bytes).
NAME = re.compile(r'[a-z][a-z0-9]{0,6}\Z')
BLOCKS = {'ca', 'cert', 'key', 'tls-auth', 'tls-crypt', 'tls-crypt-v2', 'auth-user-pass'}
# No arbitrary file paths, executable hooks, plugin, management, setenv, config,
# connection, daemon, log, writepid, user/group, route-delay or route-method.
OPTIONS = {
    'client', 'tls-client', 'nobind', 'remote', 'proto', 'resolv-retry',
    'connect-retry', 'connect-retry-max', 'connect-timeout', 'server-poll-timeout',
    'remote-random', 'remote-random-hostname', 'remote-cert-tls', 'verify-x509-name',
    'auth', 'cipher', 'data-ciphers', 'data-ciphers-fallback', 'tls-version-min',
    'tls-version-max', 'tls-cipher', 'tls-ciphersuites', 'key-direction',
    'auth-nocache', 'reneg-sec', 'hand-window', 'tran-window', 'ping',
    'ping-restart', 'ping-exit', 'explicit-exit-notify', 'sndbuf', 'rcvbuf',
    'tun-mtu', 'mssfix', 'auth-retry', 'tls-timeout', 'verb', 'mute',
}
STRIP = {'dev', 'dev-type', 'persist-key', 'persist-tun', 'pull', 'route-noexec',
         'route-nopull', 'redirect-gateway', 'redirect-private', 'dhcp-option',
         'route-ipv6', 'ifconfig-ipv6', 'block-outside-dns', 'register-dns',
         'ip-win32', 'windows-driver', 'route-metric', 'route-gateway', 'topology'}


class Error(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Error(message)


def name_ok(name):
    require(bool(NAME.fullmatch(name)), 'Имя: 1–7 строчных латинских букв/цифр, первая — буква.')
    return name


def networks(values):
    result = []
    for value in values:
        try:
            n = ipaddress.ip_network(value, strict=False)
        except ValueError:
            raise Error('Некорректная подсеть (значение скрыто).') from None
        require(n.version == 4 and any(n.subnet_of(p) for p in PRIVATE),
                'Разрешены только IPv4-подсети RFC1918; default, public и IPv6 запрещены.')
        result.append(n)
    return [str(n) for n in ipaddress.collapse_addresses(result)]


def parse_route(tokens):
    require(1 <= len(tokens) <= 4, 'Некорректная директива route.')
    try:
        network = ipaddress.IPv4Network(tokens[0] + '/' + (tokens[1] if len(tokens) > 1 else '32'), strict=False)
    except ValueError:
        raise Error('route требует числовые IPv4 network/netmask.') from None
    # Ignore redirect equivalents from profiles and push, even if written as route.
    if network.prefixlen <= 1:
        return []
    return networks([str(network)])


def lan_credentials(username, password):
    for value in (username, password):
        require(isinstance(value, str) and 0 < len(value) <= 256 and
                not any(c in value for c in '\r\n\x00') and not value.lstrip().startswith('<'),
                'Некорректный логин/пароль ЛВС.')
    return username, password


def import_client(name, source, extra=(), auth=None):
    name_ok(name)
    text = Path(source).read_text(encoding='utf-8-sig').replace('\r\n', '\n').replace('\r', '\n')
    lines, subnets, block, payload = [], list(extra), None, []
    seen = set()
    prompt = False
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if block:
            if stripped == '</' + block + '>':
                lines.extend(['<' + block + '>', *payload, '</' + block + '>'])
                block, payload = None, []
            else:
                require(not re.match(r'</?[A-Za-z][^>]*>', stripped), 'Вложенные inline-блоки запрещены.')
                payload.append(line)
            continue
        if not stripped or stripped.startswith(('#', ';')):
            continue
        if stripped.startswith('<'):
            require(stripped.startswith('<') and stripped.endswith('>'), 'Некорректный inline-блок.')
            block = stripped[1:-1]
            require(block in BLOCKS and block not in seen, 'Неподдерживаемый/повторный inline-блок.')
            seen.add(block)
            continue
        try:
            tokens = shlex.split(line, comments=True, posix=True)
        except ValueError:
            raise Error('Неверные кавычки в профиле, строка ' + str(number)) from None
        if not tokens:
            continue
        option = tokens[0].removeprefix('--')
        args = tokens[1:]
        require(all('\n' not in a and '\x00' not in a for a in args), 'Некорректный аргумент.')
        if option == 'route':
            subnets.extend(parse_route(args))
        elif option == 'pull-filter':
            # Never retain caller-supplied accept filters (first match wins).
            require(len(args) == 2 and args[0] in ('accept', 'ignore', 'reject'), 'Некорректный pull-filter.')
        elif option in STRIP:
            continue
        elif option == 'auth-user-pass' and not args:
            # Interactive credentials: supplied by the owner (stdin/no-echo prompt), stored root-only inline.
            prompt = True
        elif option in BLOCKS:
            require(args == ['[inline]'], 'Сертификаты/ключи/auth должны быть inline; внешние пути запрещены.')
        else:
            require(option in OPTIONS, 'Запрещённая/неподдерживаемая директива, строка ' + str(number))
            require(len(args) <= 8, 'Слишком много аргументов.')
            if option in ('verb', 'mute'):
                continue
            if option == 'proto':
                require(args in (['tcp'], ['tcp-client'], ['udp'], ['udp4'], ['tcp4-client']), 'Неподдерживаемый proto.')
            if option == 'remote':
                require(1 <= len(args) <= 3 and re.fullmatch(r'[A-Za-z0-9_.:-]+', args[0]) is not None,
                        'Некорректный remote.')
            # Double quotes, no shell interpretation: OpenVPN has its own parser.
            lines.append(option + ''.join(' "' + a.replace('\\', '\\\\').replace('"', '\\"') + '"' for a in args))
    require(block is None, 'Незакрытый inline-блок.')
    if prompt or auth:
        require(auth is not None, 'Профиль требует логин и пароль ЛВС: --auth-stdin или --ask-auth.')
        require('auth-user-pass' not in seen or not prompt, 'Повторный auth-user-pass.')
        start = lines.index('<auth-user-pass>') if 'auth-user-pass' in seen else None
        if start is not None:
            del lines[start:lines.index('</auth-user-pass>', start) + 1]
        lines.extend(['<auth-user-pass>', *lan_credentials(*auth), '</auth-user-pass>'])
    require(any(l.startswith('remote ') for l in lines), 'В профиле отсутствует remote.')
    require('ca' in seen or any(l.startswith('peer-fingerprint ') for l in lines), 'Требуется inline CA.')
    # A profile cannot weaken server certificate role checking.
    lines = [l for l in lines if not l.startswith('remote-cert-tls ')]
    lines.extend(['client', 'dev tun-lan-' + name, 'dev-type tun', 'nobind',
                  'remote-cert-tls server', 'auth-nocache', 'route-noexec',
                  'pull-filter ignore "redirect-gateway"',
                  'pull-filter ignore "redirect-private"',
                  'pull-filter ignore "dhcp-option"',
                  'pull-filter ignore "route-ipv6"',
                  'pull-filter ignore "ifconfig-ipv6"',
                  'pull-filter ignore "block-ipv6"',
                  # OpenVPN 2.6+/2.7 "dns" options (dns-updown) must never change server DNS.
                  'pull-filter ignore "dns"',
                  'script-security 2',
                  'route-up "/usr/local/lib/remoteagents/lan/lan-vpn.sh _hook ' + name + '"',
                  'verb 0', 'mute 1'])
    return '\n'.join(lines) + '\n', networks(subnets)


def pushed_routes(env):
    values = []
    for key in sorted(env):
        if re.fullmatch(r'route_network_[0-9]+', key):
            index = key.rsplit('_', 1)[1]
            values.extend(parse_route([env[key], env.get('route_netmask_' + index, '255.255.255.255')]))
    return networks(values)


def nft_rules(profiles):
    lines = ['table inet ' + TABLE + ' {',
             ' chain input { type filter hook input priority -10; policy accept;']
    for name, data in sorted(profiles.items()):
        name_ok(name)
        nets = networks(data['subnets'])
        if nets:
            lines.append('  iifname "tun-lan-' + name + '" ip saddr { ' + ', '.join(nets) + ' } ct state established,related accept')
    lines += ['  iifname "tun-lan-*" drop', ' }',
              ' chain forward { type filter hook forward priority -10; policy accept;',
              '  iifname "tun-lan-*" drop', '  oifname "tun-lan-*" drop', ' }']
    # postrouting also covers policy reroutes after output and forwarded traffic.
    for chain, hook, priority in [('output', 'output', '-10'), ('egress', 'postrouting', '300')]:
        lines.append(' chain ' + chain + ' { type filter hook ' + hook + ' priority ' + priority + '; policy accept;')
        for name, data in sorted(profiles.items()):
            nets = networks(data['subnets'])
            if nets:
                lines.append('  oifname "tun-lan-' + name + '" ip daddr { ' + ', '.join(nets) + ' } accept')
        lines += ['  oifname "tun-lan-*" drop', ' }']
    return '\n'.join(lines + ['}']) + '\n'


def patch_singbox(config, old, new):
    # Change ONLY managed exclusions. Reject incompatible ingress setup.
    config = json.loads(json.dumps(config))
    require(config.get('route', {}).get('final') == 'proxy-out', 'Ожидается final=proxy-out.')
    require(any(r.get('ip_is_private') is True and r.get('outbound') == 'direct-out'
                for r in config.get('route', {}).get('rules', [])), 'Нет правила private → direct-out.')
    tun = [i for i in config.get('inbounds', []) if i.get('type') == 'tun' and i.get('auto_route')]
    require(len(tun) == 1, 'Ожидается один TUN auto_route.')
    require(not tun[0].get('auto_redirect'), 'auto_redirect требует отдельной проверки; применение запрещено.')
    current = tun[0].get('route_exclude_address', [])
    require(isinstance(current, list), 'Неподдерживаемый формат exclusions.')
    values = list(dict.fromkeys([v for v in current if v not in old] + new))
    if values:
        tun[0]['route_exclude_address'] = values
    else:
        tun[0].pop('route_exclude_address', None)
    return config


def exclusion_diff(before, after):
    # Show exact changed values only, never unchanged JSON context (which may
    # contain proxy endpoint exclusions, UUIDs and inline authentication).
    result = []
    for index, (old, new) in enumerate(zip(before['inbounds'], after['inbounds'])):
        a = old.get('route_exclude_address', [])
        b = new.get('route_exclude_address', [])
        removed, added = [v for v in a if v not in b], [v for v in b if v not in a]
        if removed or added:
            result += ['--- /etc/sing-box/config.json (прочие поля без изменений)',
                       '+++ проект', '@@ inbounds[' + str(index) + '].route_exclude_address @@']
            result.extend('- ' + v for v in removed)
            result.extend('+ ' + v for v in added)
    return '\n'.join(result) + ('\n' if result else '')


def network_pending():
    return [str(p) for p in PENDING if p.exists()]


def publish(name, value):
    # Status for non-root readers: constants and booleans only, never secrets or addresses.
    PUBLIC.mkdir(mode=0o755, parents=True, exist_ok=True)
    os.chmod(PUBLIC, 0o755)
    atomic(PUBLIC / (name + '.json'), json.dumps(value, ensure_ascii=False) + '\n', 0o644)


def publish_lan():
    rows = []
    for name, data in profiles().items():
        status = STATE / (name + '.json')
        last = read(status) if status.exists() else {'ok': False, 'summary': 'не проверено', 'updatedAt': None}
        rows.append({'name': name, 'enabled': data['enabled'], 'ready': data['ready'], 'ok': last['ok'],
                     'summary': last['summary'], 'updatedAt': last['updatedAt']})
    publish('lan', rows)


def public_status():
    path = PUBLIC / 'lan.json'
    rows = read(path) if path.exists() else []
    for row in rows if isinstance(rows, list) else []:
        if isinstance(row, dict) and NAME.fullmatch(str(row.get('name', ''))):
            row['active'] = run(['systemctl', 'is-active', '--quiet', service(row['name'])], check=False).returncode == 0
            print(json.dumps(row, ensure_ascii=False))


def now():
    return datetime.now(timezone.utc).isoformat()


def atomic(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd, mode)
        if os.geteuid() == 0:
            os.fchown(fd, 0, 0)
        with os.fdopen(fd, 'w') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def save(path, value):
    atomic(path, json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def read(path):
    return json.loads(Path(path).read_text())


def run(args, check=True, input=None, timeout=20):
    try:
        p = subprocess.run([str(a) for a in args], input=input, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise Error('Команда недоступна или истёк таймаут: ' + str(args[0])) from None
    if check and p.returncode:
        raise Error('Проверка/команда завершилась ошибкой: ' + str(args[0]) + ' (вывод скрыт).')
    return p


def event(name, summary, ok=False):
    # Only application constants go here; never subprocess stderr or config data.
    LOG.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, 'a') as f:
        f.write(now() + ' ' + name + ' ' + summary + '\n')
    if NAME.fullmatch(name):
        save(STATE / (name + '.json'), {'ok': ok, 'summary': summary, 'updatedAt': now()})
        with contextlib.suppress(Exception):
            publish_lan()


def profiles():
    return {p.parent.name: profile(p.parent.name) for p in sorted(ETC.glob('*/config.json'))}


def active():
    return {n: p for n, p in profiles().items() if p.get('enabled')}


def profile(name):
    name_ok(name)
    require((ETC / name / 'config.json').is_file(), 'ЛВС не добавлена.')
    data = read(ETC / name / 'config.json')
    require(data.get('version') == 1 and data.get('$schema') == '../config.schema.json', 'Неподдерживаемая схема config.json.')
    require(type(data.get('table')) is int and 42000 <= data['table'] <= 42063 and
            type(data.get('priority')) is int and data['priority'] == data['table'] - 41000,
            'Недопустимая таблица/приоритет в config.json.')
    require(type(data.get('enabled')) is bool and type(data.get('ready')) is bool, 'Неверные flags в config.json.')
    require(isinstance(data.get('static'), list) and isinstance(data.get('subnets'), list), 'Неверный список подсетей.')
    require(networks(data['static']) == data['static'] and networks(data['subnets']) == data['subnets'],
            'В config.json нужны канонические RFC1918-подсети.')
    return data


def update(name, data):
    directory = ETC / name
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    if os.geteuid() == 0:
        os.chown(directory, 0, 0)
    save(ETC / name / 'config.json', data)
    atomic(ETC / name / 'subnets', ''.join(s + '\n' for s in data['subnets']))


def service(name):
    return 'remoteagents-lan@' + name + '.service'


def guard_batch(data):
    present = run(['nft', 'list', 'table', 'inet', TABLE], check=False).returncode == 0
    return ('delete table inet ' + TABLE + '\n' if present else '') + nft_rules(data)


def firewall(data):
    batch = guard_batch(data)
    run(['nft', '-c', '-f', '-'], input=batch)
    run(['nft', '-f', '-'], input=batch)
    # Normalize kernel JSON for subsequent drift detection; handles are irrelevant.
    save(STATE / 'firewall.json', nft_identity())


def nft_identity():
    raw = json.loads(run(['nft', '-j', 'list', 'table', 'inet', TABLE]).stdout)
    def strip(x):
        if isinstance(x, dict):
            return {k: strip(v) for k, v in x.items() if k not in ('handle', 'metainfo', 'packets', 'bytes')}
        if isinstance(x, list):
            return [strip(v) for v in x if not (isinstance(v, dict) and 'metainfo' in v)]
        return x
    return strip(raw)


def checked_singbox(old, new):
    before = read(SB)
    after = patch_singbox(before, old, new)
    if after == before:
        run(['sing-box', 'check', '-c', SB])
        return None
    print(exclusion_diff(before, after), end='', flush=True)
    candidate = STATE / 'sing-box.candidate.json'
    save(candidate, after)
    run(['sing-box', 'check', '-c', candidate])
    return candidate


def apply_singbox(candidate):
    if candidate is None:
        return
    st = SB.stat()
    atomic(SB, candidate.read_text(), st.st_mode & 0o777)
    os.chown(SB, st.st_uid, st.st_gid)
    run(['systemctl', 'restart', 'sing-box'])
    require(run(['systemctl', 'is-active', '--quiet', 'sing-box'], check=False).returncode == 0,
            'sing-box не активен.')


def managed_subnets():
    p = STATE / 'managed-subnets.json'
    return read(p) if p.exists() else []


def sync_singbox():
    new = sorted({s for p in active().values() for s in p['subnets']})
    # Do not take ownership of pre-existing exclusions: remove only our additions.
    old = managed_subnets()
    current = [s for i in read(SB)['inbounds'] if i.get('type') == 'tun'
               for s in i.get('route_exclude_address', [])]
    owned = [s for s in new if s in old or s not in current]
    candidate = checked_singbox(old, new)
    apply_singbox(candidate)
    save(STATE / 'managed-subnets.json', owned)


def route_ops(name, data, remove=False):
    # Dedicated table + rules ahead of sing-box (normally preference 9000).
    table, pref = str(data['table']), str(data['priority'])
    if remove:
        for subnet in data['subnets']:
            while run(['ip', '-4', 'rule', 'del', 'pref', pref, 'to', subnet, 'lookup', table], check=False).returncode == 0:
                pass
        run(['ip', '-4', 'route', 'flush', 'table', table], check=False)
        remaining = json.loads(run(['ip', '-j', '-4', 'rule', 'show']).stdout)
        require(not any(r.get('priority') == data['priority'] and str(r.get('table')) == table for r in remaining),
                'Не удалось убрать policy rules ЛВС.')
        remaining_routes = run(['ip', '-j', '-4', 'route', 'show', 'table', table], check=False)
        require(remaining_routes.returncode != 0 or not json.loads(remaining_routes.stdout or '[]'),
                'Не удалось очистить таблицу маршрутов ЛВС.')
        return
    run(['ip', '-4', 'route', 'replace', 'unreachable', 'default', 'table', table, 'metric', '32760'])
    rules = json.loads(run(['ip', '-j', '-4', 'rule', 'show']).stdout)
    for subnet in data['subnets']:
        run(['ip', '-4', 'route', 'replace', subnet, 'dev', 'tun-lan-' + name, 'table', table])
        if not any(r.get('priority') == data['priority'] and str(r.get('table')) == table and
                   r.get('dst') and str(ipaddress.ip_network(r['dst'], strict=False)) == subnet for r in rules):
            run(['ip', '-4', 'rule', 'add', 'pref', pref, 'to', subnet, 'lookup', table])


def preflight(data):
    require(shutil.which('sing-box') is not None, 'Нужен установленный sing-box.')
    require(run(['systemctl', 'is-active', '--quiet', 'sing-box'], check=False).returncode == 0, 'sing-box не активен.')
    patch_singbox(read(SB), [], [])
    rules = json.loads(run(['ip', '-j', '-4', 'rule', 'show']).stdout)
    own = {(p['priority'], str(p['table'])) for p in profiles().values()}
    for r in rules:
        priority = r.get('priority', 32766)
        if 0 < priority <= data['priority']:
            require((priority, str(r.get('table'))) in own, 'Конфликт приоритета policy routing.')
    routes = run(['ip', '-j', '-4', 'route', 'show', 'table', str(data['table'])], check=False)
    require(routes.returncode != 0 or not json.loads(routes.stdout or '[]'), 'Таблица маршрутов уже занята.')
    run(['sing-box', 'check', '-c', SB])
    run(['nft', '-c', '-f', '-'], input=guard_batch(active()))


def baseline(url):
    require(url.startswith('https://') and '\n' not in url and len(url) <= 2048, 'Нужен HTTPS URL проверки IP.')
    def get(proxy):
        args = ['curl', '--disable', '--fail', '--silent', '--max-time', '15', '--noproxy', '', '--proxy',
                'socks5h://127.0.0.1:1080' if proxy else '', url]
        result = run(args).stdout.strip()
        try:
            ip = ipaddress.ip_address(result)
        except ValueError:
            raise Error('Сервис проверки IP вернул некорректный ответ.') from None
        require(ip.is_global, 'Сервис проверки IP должен возвращать публичный IP.')
        return str(ip)
    proxied, system = get(True), get(False)
    require(proxied == system, 'Системный выход и proxy-out различаются; продолжение запрещено.')
    return hashlib.sha256(system.encode()).hexdigest()


def start_transaction(name, kind):
    require(not network_pending() and not (STATE / 'pending').exists(),
            'Есть неподтверждённое изменение сети (ЛВС, прокси или port-leak); confirm или rollback.')
    pending = STATE / 'pending'
    staging = STATE / '.transaction'
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(mode=0o700)
    try:
        stat = SB.stat()
        shutil.copy2(SB, staging / 'sing-box.json')
        os.chmod(staging / 'sing-box.json', 0o600)
        save(staging / 'profiles.json', profiles())
        save(staging / 'managed.json', managed_subnets())
        previous_nft = run(['nft', 'list', 'table', 'inet', TABLE], check=False)
        save(staging / 'nft.json', {'present': previous_nft.returncode == 0, 'text': previous_nft.stdout})
        save(staging / 'meta.json', {'name': name, 'kind': kind, 'created': time.time(),
                                     'uid': stat.st_uid, 'gid': stat.st_gid, 'mode': stat.st_mode & 0o777})
        os.replace(staging, pending)
        # Arm BEFORE the first network mutation. Boot recovery covers reboot.
        run(['systemd-run', '--quiet', '--unit=remoteagents-lan-rollback', '--on-active=5m',
             '--timer-property=AccuracySec=1s', str(BIN / 'lan-vpn.sh'), 'rollback'])
    except Exception:
        shutil.rmtree(pending, ignore_errors=True)
        shutil.rmtree(staging, ignore_errors=True)
        raise
    event(name, 'pending: автоматический откат через 5 минут')


def cancel_timer():
    run(['systemctl', 'stop', 'remoteagents-lan-rollback.timer'], check=False)
    run(['systemctl', 'reset-failed', 'remoteagents-lan-rollback.service'], check=False)


def rollback(boot=False):
    pending = STATE / 'pending'
    require(pending.exists(), 'Нет ожидающего отката.')
    meta, previous = read(pending / 'meta.json'), read(pending / 'profiles.json')
    # Fail closed first. Existing LANs are intentionally stopped as well.
    current = profiles()
    stop_clients(current, boot)
    for name, data in current.items():
        run(['systemctl', 'disable', service(name)], check=False)
        route_ops(name, data, remove=True)
    snapshot = read(pending / 'nft.json')
    exists = run(['nft', 'list', 'table', 'inet', TABLE], check=False).returncode == 0
    batch = ('delete table inet ' + TABLE + '\n' if exists else '')
    if snapshot['present']:
        batch += snapshot['text']
    if batch:
        run(['nft', '-c', '-f', '-'], input=batch)
        run(['nft', '-f', '-'], input=batch)
    if snapshot['present']:
        save(STATE / 'firewall.json', nft_identity())
    else:
        (STATE / 'firewall.json').unlink(missing_ok=True)
    for name, data in previous.items():
        data.update(enabled=False, ready=False)
        update(name, data)
    for name in set(current) - set(previous):
        current[name].update(enabled=False, ready=False)
        update(name, current[name])
    backup = pending / 'sing-box.json'
    run(['sing-box', 'check', '-c', backup])
    print(exclusion_diff(read(SB), read(backup)), end='', flush=True)
    atomic(SB, backup.read_text(), meta['mode'])
    os.chown(SB, meta['uid'], meta['gid'])
    # Old exclusions may remain but no LAN interface is up; there is no Internet LAN path.
    save(STATE / 'managed-subnets.json', read(pending / 'managed.json'))
    if not boot:
        run(['systemctl', 'restart', 'sing-box'])
    event(meta['name'], 'rollback: все клиенты ЛВС остановлены; sing-box/nft восстановлены')
    shutil.rmtree(pending)
    cancel_timer()
    print('Откат выполнен; ранее включённые ЛВС включаются владельцем заново.')


def install_runtime():
    require(shutil.which('nft') is not None, 'Установите nftables: sudo apt-get install nftables')
    if not shutil.which('openvpn'):
        run(['apt-get', 'update'], timeout=120)
        run(['apt-get', 'install', '-y', '--no-install-recommends', 'openvpn'], timeout=180)
    require(shutil.which('openvpn') is not None, 'Не найден openvpn.')
    BIN.mkdir(mode=0o755, parents=True, exist_ok=True)
    here = Path(__file__).resolve().parent
    for file in ('lan-vpn.sh', 'lan_vpn.py', 'lan-config.schema.json'):
        if (here / file) != (BIN / file):
            atomic(BIN / file, (here / file).read_text(), 0o755 if file.endswith('.sh') else 0o644)
    atomic(ETC / 'config.schema.json', (BIN / 'lan-config.schema.json').read_text())
    units = {
        'remoteagents-lan@.service': '''[Unit]
Description=Restricted LAN OpenVPN client %i
Requires=remoteagents-lan-firewall.service
After=network-online.target sing-box.service remoteagents-lan-firewall.service remoteagents-lan-recover.service
Wants=network-online.target
[Service]
Type=simple
ExecStartPre=/usr/local/lib/remoteagents/lan/lan-vpn.sh _prestart %i
ExecStart=/usr/sbin/openvpn --config /etc/remoteagents/lan/%i/client.conf
ExecStopPost=/usr/local/lib/remoteagents/lan/lan-vpn.sh _down %i
Restart=no
UMask=0077
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
''',
        'remoteagents-lan-firewall.service': '''[Unit]
Description=LAN kernel guard
After=remoteagents-lan-recover.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/remoteagents/lan/lan-vpn.sh _firewall
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
''',
        'remoteagents-lan-recover.service': '''[Unit]
Description=Recover unconfirmed LAN transaction after reboot
DefaultDependencies=no
After=local-fs.target
Before=sing-box.service remoteagents-lan-firewall.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/remoteagents/lan/lan-vpn.sh _recover
[Install]
WantedBy=multi-user.target
''',
        'remoteagents-lan-watch.service': '''[Unit]
Description=Check LAN firewall and routes
After=remoteagents-lan-firewall.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/remoteagents/lan/lan-vpn.sh _watch
UMask=0077
''',
        'remoteagents-lan-watch.timer': '''[Unit]
Description=Check LAN safety every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=1s
[Install]
WantedBy=timers.target
'''}
    for name, text in units.items():
        atomic(Path('/etc/systemd/system') / name, text, 0o644)
    run(['systemd-analyze', 'verify', *[str(Path('/etc/systemd/system') / n) for n in units]])
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'enable', 'remoteagents-lan-recover.service', 'remoteagents-lan-firewall.service', 'remoteagents-lan-watch.timer'])
    run(['systemctl', 'start', 'remoteagents-lan-watch.timer'])


def hook(name):
    # Only trusted generated config calls this; do not acquire the manager lock:
    # enable is waiting for discovery while holding it.
    name_ok(name)
    require(os.environ.get('dev') == 'tun-lan-' + name, 'Неожиданный интерфейс OpenVPN.')
    prestart(name)
    data = profile(name)
    found = networks(data['static'] + pushed_routes(os.environ))
    require(found, 'ЛВС не прислала частных подсетей; задайте --subnet.')
    save(STATE / (name + '.discovery.json'), {'subnets': found, 'pid': os.getppid()})
    if not data.get('ready'):
        return
    require(found == data['subnets'], 'Push-маршруты изменились; требуется повторный enable.')
    route_ops(name, data)
    apply_dns(name, data)
    event(name, 'connected: ожидается test; kernel guard установлен')


def prestart(name):
    data = profile(name)
    require(data.get('enabled'), 'ЛВС выключена.')
    require(not (STATE / 'pending').exists() or read(STATE / 'pending/meta.json')['name'] == name,
            'Есть другая незавершённая транзакция.')
    require((STATE / 'firewall.json').exists() and nft_identity() == read(STATE / 'firewall.json'),
            'Kernel guard отсутствует/изменён.')


def stop_client(name, boot=False):
    revert_dns(name)
    try:
        result = run(['systemctl', 'stop', *(['--no-block'] if boot else []), service(name)], check=False)
        stopped = result.returncode == 0
    except Error:
        stopped = False
    if not stopped:
        run(['systemctl', 'kill', '--kill-whom=all', '--signal=SIGKILL', service(name)], check=False)
    run(['ip', 'link', 'set', 'dev', 'tun-lan-' + name, 'down'], check=False)
    require(run(['systemctl', 'is-active', '--quiet', service(name)], check=False).returncode != 0,
            'Клиент ЛВС ещё активен; firewall сохранён.')
    link = run(['ip', '-j', 'link', 'show', 'dev', 'tun-lan-' + name], check=False)
    require(link.returncode != 0 or all('UP' not in x.get('flags', []) for x in json.loads(link.stdout)),
            'Интерфейс ЛВС ещё поднят; firewall сохранён.')


def stop_clients(names, boot=False):
    failed = False
    for name in names:
        try:
            stop_client(name, boot)
        except Exception:
            failed = True
            event(name, 'unsafe: остановка не подтверждена; firewall не удалён')
    require(not failed, 'Не все клиенты остановлены; guard сохранён, требуется диагностика владельца.')


def revert_dns(name):
    if shutil.which('resolvectl'):
        run(['resolvectl', 'revert', 'tun-lan-' + name], check=False)


def apply_dns(name, data):
    if not data.get('dns'):
        return
    require(shutil.which('resolvectl') is not None, 'Для split-DNS нужен systemd-resolved/resolvectl.')
    interface = 'tun-lan-' + name
    run(['resolvectl', 'default-route', interface, 'no'])
    run(['resolvectl', 'domain', interface, '~' + data['dns']['domain']])
    run(['resolvectl', 'dns', interface, data['dns']['server']])


def enable(name, url):
    data = profile(name)
    if data.get('enabled'):
        require(run(['systemctl', 'is-active', '--quiet', service(name)], check=False).returncode == 0,
                'Флаг enabled без активного клиента: сначала disable.')
        print('ЛВС уже включена; проверяйте test/status.')
        return
    for other, p in active().items():
        if other != name:
            require(not any(ipaddress.ip_network(a).overlaps(ipaddress.ip_network(b))
                            for a in data['static'] for b in p['subnets']), 'Подсети разных ЛВС пересекаются.')
    preflight(data)
    local_conflicts(data['static'])
    before_ip = baseline(url)
    start_transaction(name, 'enable')
    try:
        data.update(enabled=True, ready=False, ip_url=url, baseline=before_ip)
        update(name, data)
        firewall(active())
        # Required service start is now safe, before the TUN is created.
        run(['systemctl', 'start', 'remoteagents-lan-firewall.service'])
        discovery = STATE / (name + '.discovery.json')
        discovery.unlink(missing_ok=True)
        run(['systemctl', 'start', service(name)])
        deadline = time.monotonic() + 20
        while not discovery.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        require(discovery.exists(), 'Нет push/route за 20 с; подключение не подтверждено.')
        data['subnets'] = networks(read(discovery)['subnets'])
        for other, p in active().items():
            if other != name:
                require(not any(ipaddress.ip_network(a).overlaps(ipaddress.ip_network(b))
                                for a in data['subnets'] for b in p['subnets']), 'Подсети разных ЛВС пересекаются.')
        local_conflicts(data['subnets'])
        if data.get('dns'):
            dns_ip = ipaddress.IPv4Address(data['dns']['server'])
            require(any(dns_ip in ipaddress.ip_network(s) for s in data['subnets']), 'DNS-сервер должен входить в подсети ЛВС.')
        update(name, data)
        # All mutations are prechecked; the rollback timer is already armed.
        run(['nft', '-c', '-f', '-'], input=guard_batch(active()))
        new = sorted({s for p in active().values() for s in p['subnets']})
        checked_singbox(managed_subnets(), new)
        firewall(active())
        sync_singbox()
        route_ops(name, data)
        apply_dns(name, data)
        data['ready'] = True
        update(name, data)
        require(baseline(url) == before_ip, 'После включения изменился выходной IP.')
        audit_routes(name, data)
        event(name, 'pending: нужны test и confirm до истечения 5 минут')
        print('ЛВС подготовлена. Выполните test, проверьте новый SSH к серверу и confirm в течение 5 минут.')
    except Exception:
        rollback()
        raise


def local_conflicts(subnets):
    # A LAN must never shadow the server's own networks (docker, provider private net,
    # sing-box TUN): its policy rules would capture that traffic.
    nets = [ipaddress.ip_network(s) for s in subnets]
    for r in json.loads(run(['ip', '-j', '-4', 'route', 'show', 'table', 'main']).stdout or '[]'):
        dst, dev = r.get('dst', 'default'), r.get('dev', '')
        if dst == 'default' or dev.startswith('tun-lan-'):
            continue
        try:
            local = ipaddress.ip_network(dst, strict=False)
        except ValueError:
            continue
        require(not any(n.overlaps(local) for n in nets),
                'Подсеть ЛВС пересекается с сетью сервера (интерфейс ' + (dev if re.fullmatch(r'[A-Za-z0-9_.@-]{1,15}', dev) else '?') + ').')
    for inbound in read(SB).get('inbounds', []):
        if inbound.get('type') == 'tun':
            addresses = inbound.get('address', [])
            for address in addresses if isinstance(addresses, list) else [addresses]:
                with contextlib.suppress(ValueError, TypeError):
                    require(not any(n.overlaps(ipaddress.ip_network(address, strict=False)) for n in nets),
                            'Подсеть ЛВС пересекается с адресом TUN sing-box.')


def audit_routes(name, data):
    iface = 'tun-lan-' + name
    # Check every table, not only main; connected TUN addressing is untrusted too.
    routes = json.loads(run(['ip', '-j', '-4', 'route', 'show', 'table', 'all']).stdout)
    for r in routes:
        if r.get('dev') == iface or any(h.get('dev') == iface for h in r.get('nexthops', [])):
            destination = r.get('dst', 'default')
            require(destination != 'default', 'Обнаружен default через ЛВС.')
            networks([destination])
            # OpenVPN's private transit link can install a kernel connected
            # prefix independently of route-noexec. It is NOT added to the nft
            # destination allowlist. No public connected prefix is accepted.
            n = ipaddress.ip_network(destination, strict=False)
            require(n.prefixlen == 32 or (r.get('protocol') == 'kernel' and r.get('scope') == 'link' and not r.get('gateway'))
                    or any(n.subnet_of(ipaddress.ip_network(s)) for s in data['subnets']),
                    'Обнаружен посторонний маршрут через ЛВС.')
    v6 = json.loads(run(['ip', '-j', '-6', 'route', 'show', 'table', 'all']).stdout)
    for r in v6:
        if r.get('dev') == iface or any(h.get('dev') == iface for h in r.get('nexthops', [])):
            dst = r.get('dst', 'default')
            require(dst != 'default' and ipaddress.ip_network(dst, strict=False).subnet_of(ipaddress.ip_network('fe80::/10')),
                    'Обнаружен IPv6 через ЛВС.')
    for subnet in data['subnets']:
        n = ipaddress.ip_network(subnet)
        host = str(n.network_address + (1 if n.num_addresses > 1 else 0))
        got = json.loads(run(['ip', '-j', '-4', 'route', 'get', host]).stdout)
        require(got and got[0].get('dev') == iface and str(got[0].get('table')) == str(data['table']),
                'ip route get не подтверждает путь в интерфейс ЛВС.')


def disable(name, remove=False):
    data = profile(name)
    pending = STATE / 'pending'
    if pending.exists():
        require(read(pending / 'meta.json')['name'] == name, 'Сначала завершите другую транзакцию.')
        rollback()
        data = profile(name)
    # Stop first; removal of guards/exclusions cannot expose a live interface.
    remaining = {n: p for n, p in active().items() if n != name}
    checked_singbox(managed_subnets(), sorted({s for p in remaining.values() for s in p['subnets']}))
    run(['nft', '-c', '-f', '-'], input=guard_batch(remaining))
    start_transaction(name, 'disable')
    try:
        stop_client(name)
        run(['systemctl', 'disable', service(name)], check=False)
        route_ops(name, data, remove=True)
        data.update(enabled=False, ready=False)
        update(name, data)
        sync_singbox()
        firewall(active())
        run(['sing-box', 'check', '-c', SB])
        # All clients are stopped before the last shared guard is removed.
        if not active():
            batch = 'delete table inet ' + TABLE + '\n'
            run(['nft', '-c', '-f', '-'], input=batch)
            run(['nft', '-f', '-'], input=batch)
            (STATE / 'firewall.json').unlink(missing_ok=True)
        # No network mutation below; only now retire the rollback.
        shutil.rmtree(STATE / 'pending')
        cancel_timer()
        event(name, 'disabled: клиент остановлен, маршруты и exclusions удалены')
        if remove:
            shutil.rmtree(ETC / name)
            for suffix in ('.json', '.discovery.json', '.test.json'):
                (STATE / (name + suffix)).unlink(missing_ok=True)
        if not active():
            run(['systemctl', 'disable', '--now', 'remoteagents-lan-firewall.service',
                 'remoteagents-lan-watch.timer', 'remoteagents-lan-recover.service'])
        print('ЛВС удалена.' if remove else 'ЛВС выключена.')
    except Exception:
        if (STATE / 'pending').exists():
            rollback()
        raise


def test_host(name, host, port):
    data = profile(name)
    require(data.get('enabled') and data.get('ready'), 'ЛВС не готова.')
    try:
        target = ipaddress.IPv4Address(host)
    except ValueError:
        raise Error('Для test нужен числовой IPv4 хоста ЛВС.') from None
    require(any(target in ipaddress.ip_network(s) for s in data['subnets']), 'Хост не входит в подсети ЛВС.')
    audit_routes(name, data)
    require(nft_identity() == read(STATE / 'firewall.json'), 'Kernel guard изменён.')
    got = json.loads(run(['ip', '-j', '-4', 'route', 'get', str(target)]).stdout)
    require(got[0].get('dev') == 'tun-lan-' + name, 'Хост пойдёт не через ЛВС.')
    if port is None:
        run(['ping', '-n', '-c', '1', '-W', '5', str(target)])
    else:
        require(1 <= port <= 65535, 'Порт вне диапазона.')
        try:
            with socket.create_connection((str(target), port), timeout=10):
                pass
        except OSError:
            raise Error('Хост/порт ЛВС не отвечает.') from None
    require(baseline(data['ip_url']) == data['baseline'], 'Внешний IP изменился.')
    save(STATE / (name + '.test.json'), {'at': time.time(), 'baseline': data['baseline']})
    event(name, 'test passed: хост отвечает, policy route и выход через прокси проверены', True)
    print('Проверено: хост ЛВС отвечает, внешний IP совпадает с proxy-out и исходным IP.')


def confirm(name, ssh_checked):
    require(ssh_checked, 'Нужен --ssh-checked после проверки НОВОГО SSH-соединения владельцем.')
    pending = STATE / 'pending'
    require(pending.exists() and read(pending / 'meta.json')['name'] == name, 'Нет ожидающего подтверждения.')
    tested = STATE / (name + '.test.json')
    require(tested.exists() and read(tested)['at'] >= read(pending / 'meta.json')['created'] and
            time.time() - read(tested)['at'] < 120, 'Сначала выполните свежий test (не старше 2 минут).')
    data = profile(name)
    audit_routes(name, data)
    require(nft_identity() == read(STATE / 'firewall.json'), 'Kernel guard изменён.')
    require(baseline(data['ip_url']) == data['baseline'], 'Внешний IP изменился.')
    run(['systemctl', 'enable', service(name)])
    # Delete pending BEFORE stopping the timer; a racing rollback sees no pending.
    shutil.rmtree(pending)
    cancel_timer()
    event(name, 'confirmed: test пройден; новый SSH проверен владельцем', True)
    print('Подтверждено. Автозапуск клиента включён, таймер отката снят.')


def audit_all_tunnels():
    for family in ('-4', '-6'):
        routes = json.loads(run(['ip', '-j', family, 'route', 'show', 'table', 'all']).stdout)
        for route in routes:
            devices = [route.get('dev', '')] + [h.get('dev', '') for h in route.get('nexthops', [])]
            if not any(d.startswith('tun-lan-') for d in devices):
                continue
            dst = route.get('dst', 'default')
            require(dst != 'default', 'Обнаружен default через ЛВС.')
            if family == '-4':
                networks([dst])
            else:
                require(ipaddress.ip_network(dst, strict=False).subnet_of(ipaddress.ip_network('fe80::/10')),
                        'Обнаружен IPv6 через ЛВС.')


def watch():
    data = active()
    if not data:
        return
    try:
        require(nft_identity() == read(STATE / 'firewall.json'), 'Kernel guard отсутствует/изменён.')
        audit_all_tunnels()
        for name, p in data.items():
            require(run(['systemctl', 'is-active', '--quiet', service(name)], check=False).returncode == 0,
                    'Клиент не активен.')
            require(p.get('ready'), 'Подключение не готово.')
            audit_routes(name, p)
    except Exception:
        # Block every LAN packet immediately if nft is available; still attempt
        # every client stop if the kernel firewall tool itself is unavailable.
        with contextlib.suppress(Exception):
            firewall({})
        stop_clients(data)
        for name, p in data.items():
            run(['systemctl', 'disable', service(name)], check=False)
            route_ops(name, p, remove=True)
            p.update(enabled=False, ready=False)
            update(name, p)
            event(name, 'unsafe: watchdog остановил все ЛВС; проверьте nft/маршруты/клиент')
        firewall({})
        return
    for name in data:
        # Connectivity wasn't tested by the watchdog; never claim it was.
        event(name, 'guard checked: nft/маршруты/процесс проверены; доступность хоста не проверялась', False)


def read_auth(args):
    if args.auth_stdin:
        text = sys.stdin.read().replace('\r\n', '\n')
        # sudo -S consumes its own line first; with NOPASSWD that line arrives here and is dropped.
        require(MARKER + '\n' in text, 'Нет данных после маркера stdin.')
        try:
            data = json.loads(text.split(MARKER + '\n', 1)[1])
        except ValueError:
            raise Error('Некорректные данные stdin.') from None
        require(isinstance(data, dict), 'Некорректные данные stdin.')
        return lan_credentials(data.get('username'), data.get('password'))
    if args.ask_auth:
        import getpass
        return lan_credentials(input('Логин ЛВС: ').strip(), getpass.getpass('Пароль ЛВС (не отображается): '))
    return None


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description='Restricted LAN VPN; изменения сети выполняет только владелец.')
    sub = parser.add_subparsers(dest='cmd', required=True)
    for command in ('add', 'enable'):
        p = sub.add_parser(command)
        p.add_argument('name')
        if command == 'add':
            p.add_argument('ovpn')
            p.add_argument('--subnet', action='append', default=[])
            p.add_argument('--dns-domain')
            p.add_argument('--dns-server')
            auth = p.add_mutually_exclusive_group()
            auth.add_argument('--auth-stdin', action='store_true', help='LAN login/password as JSON on stdin after the marker line')
            auth.add_argument('--ask-auth', action='store_true', help='Ask LAN login/password without echo')
        p.add_argument('--ip-check-url', required=True, help='HTTPS endpoint returning one public IP; selected by owner')
    for command in ('disable', 'remove', 'confirm', 'test', '_hook', '_prestart', '_down'):
        p = sub.add_parser(command)
        p.add_argument('name')
        if command == 'confirm':
            p.add_argument('--ssh-checked', action='store_true')
        if command == 'test':
            p.add_argument('host')
            p.add_argument('port', nargs='?', type=int)
    for command in ('list', 'status', 'public-status', 'rollback', '_watch', '_firewall', '_recover'):
        sub.add_parser(command)
    args = parser.parse_args()
    if args.cmd == 'public-status':
        public_status()
        return
    require(os.geteuid() == 0, 'Нужен sudo; агент не применяет изменения самостоятельно.')
    if hasattr(args, 'name'):
        name_ok(args.name)
    ETC.mkdir(mode=0o700, parents=True, exist_ok=True)
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(ETC, 0o700)
    os.chmod(STATE, 0o700)
    os.chown(ETC, 0, 0)
    os.chown(STATE, 0, 0)
    # Hook must not wait on enable's lock (see hook()).
    if args.cmd == '_hook':
        try:
            hook(args.name)
        except Exception:
            event(args.name, 'hook failed: небезопасный push/маршруты/guard; запрошена остановка клиента')
            run(['systemctl', 'stop', '--no-block', service(args.name)], check=False)
            raise
        return
    if args.cmd == '_firewall':
        # Called by a required unit while enable waits for systemctl start.
        if active():
            firewall(active())
        return
    if args.cmd == '_prestart':
        prestart(args.name)
        return
    if args.cmd == '_down':
        revert_dns(args.name)
        event(args.name, 'disconnected: процесс OpenVPN завершён')
        return
    with open(STATE.parent / 'network.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.cmd in ('add', 'enable'):
            require(not network_pending() and not (STATE / 'pending').exists(),
                    'Сначала confirm или rollback предыдущего изменения сети.')
        if args.cmd == 'add':
            client, static = import_client(args.name, args.ovpn, args.subnet, read_auth(args))
            require(bool(args.dns_domain) == bool(args.dns_server), 'Задайте обе опции --dns-domain и --dns-server.')
            dns = None
            if args.dns_domain:
                require(bool(re.fullmatch(r'(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', args.dns_domain)) and '.' in args.dns_domain and '..' not in args.dns_domain, 'Некорректный DNS-домен.')
                networks([args.dns_server + '/32'])
                dns = {'domain': args.dns_domain.lower(), 'server': str(ipaddress.IPv4Address(args.dns_server))}
            old = profiles()
            if args.name in old:
                require((ETC / args.name / 'client.conf').read_text() == client and old[args.name]['static'] == static and old[args.name].get('dns') == dns,
                        'Имя занято другим профилем; сначала remove.')
            else:
                used = {p['table'] for p in old.values()}
                slot = next((i for i in range(64) if 42000 + i not in used), None)
                require(slot is not None, 'Достигнут лимит 64 ЛВС.')
                data = {'$schema': '../config.schema.json', 'version': 1, 'enabled': False, 'ready': False, 'static': static,
                        'subnets': static, 'dns': dns, 'table': 42000 + slot, 'priority': 1000 + slot}
                atomic(ETC / args.name / 'client.conf', client)
                update(args.name, data)
            install_runtime()
            enable(args.name, args.ip_check_url)
        elif args.cmd == 'enable':
            install_runtime()
            enable(args.name, args.ip_check_url)
        elif args.cmd in ('disable', 'remove'):
            disable(args.name, args.cmd == 'remove')
        elif args.cmd == 'confirm':
            confirm(args.name, args.ssh_checked)
        elif args.cmd == 'test':
            test_host(args.name, args.host, args.port)
        elif args.cmd == 'rollback':
            rollback()
        elif args.cmd == '_watch':
            watch()
        elif args.cmd == '_recover':
            if (STATE / 'pending').exists():
                rollback(boot=True)
        else:
            for name, data in profiles().items():
                status = read(STATE / (name + '.json')) if (STATE / (name + '.json')).exists() else {
                    'ok': False, 'summary': 'не проверено', 'updatedAt': None}
                live = run(['systemctl', 'is-active', '--quiet', service(name)], check=False).returncode == 0
                if not live:
                    status.update(ok=False, summary='клиент не активен; ' + status['summary'])
                print(json.dumps({'name': name, 'enabled': data['enabled'], 'active': live, **status}, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # No traceback and no untrusted exception text (may contain credentials).
        message = str(exc) if isinstance(exc, Error) else 'Ошибка файла/данных; детали скрыты во избежание утечки секретов.'
        if os.geteuid() == 0:
            with contextlib.suppress(Exception):
                candidate_name = sys.argv[2] if len(sys.argv) > 2 and NAME.fullmatch(sys.argv[2]) else 'manager'
                event(candidate_name, 'error: команда не выполнена; диагностический вывод скрыт')
        print('Ошибка: ' + message, file=sys.stderr)
        sys.exit(1)
