#!/usr/bin/env python3
"""Replace ONLY the sing-box outbound proxy-out, with a 5 minute rollback and confirm.

Python is used for JSON/diff/validation; proxying itself is sing-box and the IP check
is curl. Secrets (proxy login/password) never appear in argv, diff, journal or errors:
they arrive on stdin (after a marker line) or from an interactive no-echo prompt.
"""
import argparse
import contextlib
import fcntl
import getpass
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time

# Explicit local module loading works with python -I, including installed copies.
spec = importlib.util.spec_from_file_location('lan_vpn', Path(__file__).with_name('lan_vpn.py'))
lan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lan)
STATE = Path('/var/lib/remoteagents/proxy-out')
ETC = Path('/etc/remoteagents/proxy')
BIN = Path('/usr/local/lib/remoteagents/proxy-out')
TAG = 'proxy-out'
MARKER = '---remoteagents-stdin---'
TIMER = 'remoteagents-proxy-out-rollback'
HOST = re.compile(r'(?=.{1,253}\Z)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\Z')
SECRET = re.compile(r'pass|user|uuid|key|token|secret|psk', re.I)
# Dial fields of the previous outbound that stay (they are not proxy credentials).
KEEP = ('detour', 'bind_interface', 'inet4_bind_address', 'inet6_bind_address', 'routing_mark',
        'domain_resolver', 'domain_strategy', 'connect_timeout', 'tcp_fast_open', 'udp_fragment')


def endpoint(kind, server, port):
    lan.require(kind in ('socks', 'http'), 'Тип прокси: socks (SOCKS5) или http.')
    lan.require(isinstance(server, str) and bool(HOST.fullmatch(server)) and '..' not in server
                or _is_ip(server), 'Некорректный адрес прокси.')
    lan.require(type(port) is int and 1 <= port <= 65535, 'Порт прокси вне диапазона.')
    return kind, server, port


def _is_ip(value):
    try:
        ipaddress.ip_address(value)
        return True
    except (ValueError, TypeError):
        return False


def credentials(username, password):
    username, password = username or '', password or ''
    for value in (username, password):
        lan.require(isinstance(value, str) and len(value) <= 256 and
                    not any(c in value for c in '\r\n\x00'), 'Некорректный логин/пароль прокси.')
    lan.require(':' not in username, 'Логин прокси не может содержать двоеточие.')
    lan.require(bool(username) or not password, 'Пароль без логина не поддерживается.')
    return username, password


def outbound(kind, server, port, username, password, previous=None):
    item = {'type': kind, 'tag': TAG, 'server': server, 'server_port': port}
    if kind == 'socks':
        item['version'] = '5'
    if username:
        item['username'] = username
        item['password'] = password
    for key in KEEP:
        if previous and key in previous:
            item[key] = previous[key]
    return item


def patch(config, new):
    """Return (candidate, created). Every other field of the config is preserved."""
    result = json.loads(json.dumps(config))
    outbounds = result.setdefault('outbounds', [])
    lan.require(isinstance(outbounds, list), 'Неподдерживаемый формат outbounds.')
    index = [i for i, o in enumerate(outbounds) if o.get('tag') == TAG]
    lan.require(len(index) <= 1, 'Несколько outbound proxy-out; нужна ручная проверка.')
    route = result.setdefault('route', {})
    created = not index
    if index:
        outbounds[index[0]] = outbound(*new, previous=outbounds[index[0]])
    else:
        outbounds.insert(0, outbound(*new))
    tun = [i for i in result.get('inbounds', []) if i.get('type') == 'tun' and i.get('auto_route')]
    lan.require(len(tun) == 1, 'Нужен один TUN sing-box с auto_route: без него системный трафик '
                'сервера не пойдёт через прокси. Настройте TUN отдельно.')
    if created:
        # Keep today's exclusions: private networks (and LAN TUNs) stay direct.
        if not any(o.get('tag') == 'direct-out' for o in outbounds):
            outbounds.append({'type': 'direct', 'tag': 'direct-out'})
        rules = route.setdefault('rules', [])
        if not any(r.get('ip_is_private') is True and r.get('outbound') == 'direct-out' for r in rules):
            rules.append({'ip_is_private': True, 'outbound': 'direct-out'})
        if not route.get('auto_detect_interface') and not route.get('default_interface'):
            # sing-box's own connection to the proxy must not loop back into its TUN.
            route['auto_detect_interface'] = True
    lan.require(not created or route.get('final') in (None, TAG, 'direct-out') or
                any(o.get('tag') == route.get('final') for o in outbounds),
                'Неизвестный route.final.')
    route['final'] = TAG
    return result, created


def masked(key, value):
    return '<скрыто>' if SECRET.search(key) else json.dumps(value, ensure_ascii=False)


def semantic_diff(before, after):
    """Changed values only; credential-like fields are never printed."""
    lines = ['--- /etc/sing-box/config.json (прочие поля без изменений; секреты скрыты)', '+++ кандидат']
    old = next((o for o in before.get('outbounds', []) if o.get('tag') == TAG), {})
    new = next((o for o in after.get('outbounds', []) if o.get('tag') == TAG), {})
    lines.append('@@ outbounds[' + TAG + ']' + (' (создаётся)' if not old else '') + ' @@')
    for key in sorted(set(old) | set(new)):
        if key in old and key in new and old[key] == new[key]:
            continue
        if SECRET.search(key):
            state = 'добавлен' if key not in old else 'удалён' if key not in new else 'изменён'
            lines.append('~ ' + key + ': <скрыто> (' + state + ')')
            continue
        if key in old:
            lines.append('- ' + key + ': ' + masked(key, old[key]))
        if key in new:
            lines.append('+ ' + key + ': ' + masked(key, new[key]))
    a, b = before.get('route', {}), after.get('route', {})
    for key in ('final', 'auto_detect_interface'):
        if a.get(key) != b.get(key):
            lines += ['@@ route.' + key + ' @@', '- ' + json.dumps(a.get(key)), '+ ' + json.dumps(b.get(key))]
    if len(a.get('rules', [])) != len(b.get('rules', [])):
        lines += ['@@ route.rules @@', '+ {"ip_is_private": true, "outbound": "direct-out"}']
    added = [o.get('tag') for o in after.get('outbounds', []) if o.get('tag') != TAG and
             o.get('tag') not in {x.get('tag') for x in before.get('outbounds', [])}]
    for tag in added:
        lines += ['@@ outbounds[' + str(tag) + '] (создаётся) @@', '+ type: "direct"']
    return '\n'.join(lines) + '\n'


def curl_config(proxy=None, auth=None):
    def quote(value):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
    # An explicit empty proxy also disables any proxy from the environment.
    lines = ['noproxy = ""', 'proxy = ' + quote(proxy or '')]
    if auth and auth[0]:
        lines.append('proxy-user = ' + quote(auth[0] + ':' + auth[1]))
    return '\n'.join(lines) + '\n'


def public_ip(url, proxy=None, auth=None):
    """Proxy URL and credentials go to curl via stdin config (-K -), never argv."""
    lan.require(url.startswith('https://') and '\n' not in url and len(url) <= 2048,
                'Нужен HTTPS URL проверки IP (ответ — только IP).')
    result = lan.run(['curl', '--disable', '--fail', '--silent', '--max-time', '15', '-K', '-', url],
                     input=curl_config(proxy, auth)).stdout.strip()
    try:
        ip = ipaddress.ip_address(result)
    except ValueError:
        raise lan.Error('Сервис проверки IP вернул некорректный ответ.') from None
    lan.require(ip.is_global, 'Сервис проверки IP должен возвращать публичный IP.')
    return hashlib.sha256(str(ip).encode()).hexdigest()


def proxy_url(kind, server, port):
    host = '[' + server + ']' if ':' in server else server
    return ('socks5h://' if kind == 'socks' else 'http://') + host + ':' + str(port)


def local_proxies(config):
    """Loopback mixed/socks/http inbounds of sing-box: they must also exit via the new proxy."""
    result = []
    for item in config.get('inbounds', []):
        if item.get('type') in ('mixed', 'socks', 'http') and type(item.get('listen_port')) is int:
            listen = item.get('listen', '127.0.0.1')
            if listen in ('127.0.0.1', '::1', 'localhost') and not item.get('users'):
                kind = 'http' if item['type'] == 'http' else 'socks'
                result.append(proxy_url(kind, '127.0.0.1' if listen == 'localhost' else listen, item['listen_port']))
    return result


def verify(url, expected, config):
    lan.require(public_ip(url) == expected, 'Системный выход сервера не совпадает с новым прокси.')
    for proxy in local_proxies(config):
        lan.require(public_ip(url, proxy) == expected, 'Локальный вход sing-box выходит не через новый прокси.')


def publish(summary, ok, state):
    lan.publish('proxy', {'state': state, 'ok': ok, 'summary': summary, 'updatedAt': lan.now()})


def clear_timer():
    lan.run(['systemctl', 'stop', TIMER + '.timer'], check=False)
    lan.run(['systemctl', 'reset-failed', TIMER + '.service'], check=False)


def rollback(boot=False):
    pending = STATE / 'pending'
    lan.require(pending.exists(), 'Нет ожидающего отката proxy-out.')
    backup, meta = pending / 'sing-box.json', lan.read(pending / 'meta.json')
    lan.run(['sing-box', 'check', '-c', backup])
    print(semantic_diff(lan.read(lan.SB), lan.read(backup)), end='', flush=True)
    lan.atomic(lan.SB, backup.read_text(), meta['mode'])
    os.chown(lan.SB, meta['uid'], meta['gid'])
    if not boot:
        lan.run(['systemctl', 'restart', 'sing-box'])
    shutil.rmtree(pending)
    clear_timer()
    lan.event('proxy-out', 'rollback: прежний proxy-out восстановлен')
    publish('Откат: прежний выход восстановлен; новый прокси не подтверждён', False, 'rolled-back')
    print('Откат proxy-out выполнен.')


def install():
    BIN.mkdir(mode=0o755, parents=True, exist_ok=True)
    here = Path(__file__).resolve().parent
    for name in ('proxy-out.sh', 'proxy_out.py', 'lan_vpn.py'):
        if (here / name) != (BIN / name):
            lan.atomic(BIN / name, (here / name).read_text(), 0o755 if name.endswith('.sh') else 0o644)
    unit = '''[Unit]
Description=Recover unconfirmed proxy-out change after reboot
DefaultDependencies=no
After=local-fs.target
Before=sing-box.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/remoteagents/proxy-out/proxy-out.sh _recover
[Install]
WantedBy=multi-user.target
'''
    path = Path('/etc/systemd/system/remoteagents-proxy-out-recover.service')
    lan.atomic(path, unit, 0o644)
    lan.run(['systemd-analyze', 'verify', path])
    lan.run(['systemctl', 'daemon-reload'])
    lan.run(['systemctl', 'enable', path.name])


def read_secret(args):
    if args.credentials_stdin:
        text = sys.stdin.read().replace('\r\n', '\n')
        # sudo -S consumes its own line first; with NOPASSWD that line arrives here and is dropped.
        lan.require(MARKER + '\n' in text, 'Нет данных после маркера stdin.')
        try:
            data = json.loads(text.split(MARKER + '\n', 1)[1])
        except ValueError:
            raise lan.Error('Некорректные данные stdin.') from None
        lan.require(isinstance(data, dict), 'Некорректные данные stdin.')
        return credentials(data.get('username'), data.get('password'))
    if args.ask_credentials:
        return credentials(input('Логин прокси (пусто — без авторизации): ').strip(),
                           getpass.getpass('Пароль прокси (не отображается): '))
    return '', ''


def apply(args):
    new = endpoint(args.type, args.server, args.port) + read_secret(args)
    pending = STATE / 'pending'
    lan.require(not lan.network_pending(), 'Сначала подтвердите или откатите предыдущее изменение сети.')
    before = lan.read(lan.SB)
    after, created = patch(before, new)
    if after == before:
        lan.run(['sing-box', 'check', '-c', lan.SB])
        verify(args.ip_check_url, public_ip(args.ip_check_url, proxy_url(*new[:3]), new[3:]), before)
        publish('Прокси уже настроен и проверен', True, 'confirmed')
        print('proxy-out уже такой; выход через него проверен. Изменений нет.')
        return
    print(semantic_diff(before, after), end='', flush=True)
    candidate = STATE / 'candidate.json'
    lan.save(candidate, after)
    try:
        lan.run(['sing-box', 'check', '-c', candidate])
        # The new proxy must work BEFORE anything changes: endpoint, credentials, public IP.
        expected = public_ip(args.ip_check_url, proxy_url(*new[:3]), new[3:])
        install()
        pending.mkdir(mode=0o700)
        st = lan.SB.stat()
        shutil.copy2(lan.SB, pending / 'sing-box.json')
        os.chmod(pending / 'sing-box.json', 0o600)
        lan.save(pending / 'meta.json', {'uid': st.st_uid, 'gid': st.st_gid, 'mode': st.st_mode & 0o777,
                                        'url': args.ip_check_url, 'expected': expected,
                                        'created': time.time(), 'new': created})
        try:
            # Armed BEFORE the first network mutation; the recover unit covers reboot.
            lan.run(['systemd-run', '--quiet', '--unit=' + TIMER, '--on-active=5m',
                     '--timer-property=AccuracySec=1s', BIN / 'proxy-out.sh', 'rollback'])
        except Exception:
            shutil.rmtree(pending)
            raise
        try:
            lan.apply_singbox(candidate)
            verify(args.ip_check_url, expected, after)
            lan.event('proxy-out', 'pending: выход через новый прокси проверен; нужен confirm')
            publish('Применено, ждёт подтверждения (автооткат через 5 минут)', False, 'pending')
        except Exception:
            rollback()
            raise
    finally:
        candidate.unlink(missing_ok=True)
    print('Применено с автооткатом 5 минут. Откройте НОВОЕ SSH-соединение и выполните confirm --ssh-checked.')


def confirm(ssh_checked):
    pending = STATE / 'pending'
    lan.require(pending.exists(), 'Нет ожидающего подтверждения proxy-out.')
    lan.require(ssh_checked, 'Нужен --ssh-checked после проверки НОВОГО SSH-соединения.')
    meta = lan.read(pending / 'meta.json')
    lan.run(['sing-box', 'check', '-c', lan.SB])
    lan.require(lan.run(['systemctl', 'is-active', '--quiet', 'sing-box'], check=False).returncode == 0,
                'sing-box не активен.')
    config = lan.read(lan.SB)
    verify(meta['url'], meta['expected'], config)
    item = next(o for o in config['outbounds'] if o.get('tag') == TAG)
    # Root-only copy of the chosen settings, including credentials, for later reapply.
    ETC.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(ETC, 0o700)
    lan.save(ETC / 'proxy.json', {k: item[k] for k in ('type', 'server', 'server_port', 'username', 'password') if k in item})
    # Delete pending BEFORE stopping the timer; a racing rollback sees no pending.
    shutil.rmtree(pending)
    clear_timer()
    lan.event('proxy-out', 'confirmed: выход через proxy-out проверен; новый SSH проверен', True)
    publish('Подключён ✓: выход сервера через этот прокси проверен', True, 'confirmed')
    print('Подтверждено, таймер отката снят.')


def status():
    path = lan.PUBLIC / 'proxy.json'
    print(path.read_text().strip() if path.exists() else json.dumps({'state': 'unknown', 'ok': False,
          'summary': 'не настраивался этим приложением'}, ensure_ascii=False))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description='Replace sing-box proxy-out; the owner executes and confirms.')
    sub = parser.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('apply')
    p.add_argument('--type', required=True, choices=['socks', 'http'])
    p.add_argument('--server', required=True)
    p.add_argument('--port', required=True, type=int)
    p.add_argument('--ip-check-url', required=True)
    group = p.add_mutually_exclusive_group()
    group.add_argument('--credentials-stdin', action='store_true')
    group.add_argument('--ask-credentials', action='store_true')
    sub.add_parser('confirm').add_argument('--ssh-checked', action='store_true')
    for command in ('rollback', '_recover', 'status'):
        sub.add_parser(command)
    args = parser.parse_args()
    if args.cmd == 'status':
        status()
        return
    lan.require(os.geteuid() == 0, 'Нужен root/sudo; изменения сети выполняет только владелец.')
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(STATE.parent / 'network.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.cmd == 'rollback':
            rollback()
        elif args.cmd == '_recover':
            if (STATE / 'pending').exists():
                rollback(boot=True)
        elif args.cmd == 'confirm':
            confirm(args.ssh_checked)
        else:
            apply(args)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        with contextlib.suppress(Exception):
            if os.geteuid() == 0:
                lan.event('proxy-out', 'error: команда не выполнена; диагностический вывод скрыт')
                publish('Ошибка: ' + (str(exc) if isinstance(exc, lan.Error) else 'команда не выполнена'), False, 'error')
        print('Ошибка: ' + (str(exc) if isinstance(exc, lan.Error) else 'Ошибка файла/команды; детали скрыты.'), file=sys.stderr)
        sys.exit(1)
