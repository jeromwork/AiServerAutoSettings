#!/usr/bin/env python3
"""Repair prerequisites before attempting to restore services using those tools."""
from urllib.parse import quote

DATA_PACKAGES = ('ca-certificates', 'dbus-user-session', 'libpam-systemd', 'python3-cryptography')

BASE = {'python3': 'python3', 'curl': 'curl', 'git': 'git', 'ip': 'iproute2',
        'jq': 'jq', 'nft': 'nftables', 'openssl': 'openssl', 'runuser': 'util-linux',
        'dbus-daemon': 'dbus', 'sudo': 'sudo', '/usr/sbin/sshd': 'openssh-server'}


def proxy_url(e):
    p = e.config.get('proxyOut', {})
    if p.get('type') not in ('http', 'socks'):
        return None
    host = '[' + p['server'] + ']' if ':' in p['server'] else p['server']
    auth = ''
    if p.get('login') or p.get('password'):
        password = e.secret(p['password'], 'proxy-out-password') if p.get('password') else ''
        auth = quote(p.get('login', ''), safe='') + ':' + quote(password, safe='') + '@'
    return ('http://' if p['type'] == 'http' else 'socks5h://') + auth + host + ':' + str(p['port'])


def prepare(e):
    e.s.download_proxy = proxy_url(e)


def ensure(e, apply):
    wanted = dict(BASE)
    if e.config.get('lan'):
        wanted['openvpn'] = 'openvpn'
    if e.config.get('serverNetwork', {}).get('enabled') or e.receipts.get('base-network', {}).get('managed'):
        wanted['sing-box'] = 'sing-box'
    missing = sorted({package for tool, package in wanted.items()
                      if e.s.run(['which', tool], check=False).returncode})
    missing += [p for p in DATA_PACKAGES if e.s.run(['dpkg-query', '-W', '-f=${Status}', p], check=False).stdout.strip() != 'install ok installed']
    missing = sorted(set(missing))
    if not missing:
        return True
    if apply:
        prepare(e)
        e.s.run(['apt-get', 'update'], change=True, timeout=300)
        e.s.run(['apt-get', 'install', '-y', '--no-install-recommends', '-o', 'Dpkg::Options::=--force-confold', *missing], change=True, timeout=300)
    return e.row('packages', 'ready' if apply else 'change',
                 'переустановлены зависимости' if apply else 'будут переустановлены отсутствующие пакеты')
