#!/usr/bin/env python3
"""First system TUN activation. Uses the reconciler's IO boundary, never a shell.

The timer and boot recovery run from a root-owned installed copy. A pending
transaction prevents the watcher and LAN/proxy managers from changing its state.
"""
import argparse
import importlib.util
import ipaddress
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import time

STATE = '/var/lib/remoteagents/base-network/pending'
BIN = '/usr/local/lib/remoteagents/server/base_network.py'
TIMER = 'remoteagents-base-network-rollback'


def candidate(engine):
    c, s = engine.config, engine.s
    n, p = c['serverNetwork'], c['proxyOut']
    require = _require
    require(p.get('ipv6') in ('block', 'allow') and p.get('exitIp') and p.get('checkUrl'),
            'Для первого включения нужны proxyOut.exitIp, checkUrl и ipv6 block|allow.')
    address = ipaddress.IPv4Interface(n.get('tunAddress', '172.30.250.1/30'))
    require(any(address.network.subnet_of(ipaddress.ip_network(n)) for n in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')) and 24 <= address.network.prefixlen <= 30, 'Нужна частная IPv4-подсеть TUN /24…/30.')
    # Kernel routes include LANs, connected networks and addresses of interfaces.
    routes = json.loads(s.run(['ip', '-j', '-4', 'route', 'show', 'table', 'all']).stdout)
    for route in routes:
        dest = route.get('dst', 'default')
        if dest != 'default':
            require(not address.network.overlaps(ipaddress.ip_network(dest, strict=False)),
                    'Подсеть TUN пересекается с существующим маршрутом; выберите serverNetwork.tunAddress.')
    password = engine.secret(p['password'], 'proxy-out-password') if p.get('password') else ''
    proxy = engine_module('proxy_out')
    new = proxy.outbound(*proxy.endpoint(p['type'], p['server'], p['port']),
                         *proxy.credentials(p.get('login'), password))
    extra = json.loads(engine.secret(n['inbounds'], 'server-inbounds')) if n.get('inbounds') else []
    require(isinstance(extra, list) and all(isinstance(i, dict) and i.get('type') != 'tun' for i in extra),
            'serverNetwork.inbounds: секрет должен быть JSON-массивом входов sing-box без TUN.')
    return {'log': {'level': 'warn'},
            'inbounds': [{'type': 'tun', 'tag': 'system-tun', 'interface_name': n.get('tunName', 'ra-tun'),
                          'address': [str(address)], 'auto_route': True, 'auto_redirect': False,
                          'iproute2_rule_index': 9000, 'iproute2_table_index': 2022},
                         {'type': 'mixed', 'tag': 'local-proxy', 'listen': '127.0.0.1', 'listen_port': 1080}, *extra],
            'outbounds': [new, {'type': 'direct', 'tag': 'direct-out'}],
            'route': {'auto_detect_interface': True, 'final': 'proxy-out',
                      'rules': [{'ip_is_private': True, 'outbound': 'direct-out'}]}}


def engine_module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class Error(Exception):
    pass


def _require(ok, message):
    if not ok:
        raise Error(message)


def install_packages(engine):
    s = engine.s
    s.run(['apt-get', 'update'], change=True, timeout=300)
    s.run(['apt-get', 'install', '-y', '--no-install-recommends', 'ca-certificates', 'curl', 'jq',
           'iproute2', 'nftables', 'openssl', 'sudo'], change=True, timeout=300)
    if s.run(['sing-box', 'version'], check=False).returncode == 0:
        return
    # Use the official signed apt repository, not curl|sh or an unverified binary.
    with s.private_file('') as key:
        s.run(['curl', '--disable', '--noproxy', '*', '--fail', '--silent', '--location', '--max-redirs', '3', '--max-time', '60',
               '-o', key, 'https://sing-box.app/gpg.key'])
        _require(key.read_bytes().startswith(b'-----BEGIN PGP PUBLIC KEY BLOCK-----'), 'Репозиторий sing-box не вернул открытый ключ; установка остановлена.')
        s.write('/etc/apt/keyrings/sagernet.asc', key.read_bytes(), 0o644)
    s.write('/etc/apt/sources.list.d/sagernet.list',
            'deb [signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *\n', 0o644)
    s.run(['apt-get', 'update'], change=True, timeout=300)
    s.run(['apt-get', 'install', '-y', 'sing-box'], change=True, timeout=300)


def apply(engine):
    s = engine.s
    _require(not s.path('/etc/sing-box/config.json').exists(),
             'Существующий sing-box без TUN: автоматическая замена запрещена; сохраните и проверьте его отдельно.')
    _require(not any(s.path(p).exists() for p in (
        STATE, '/var/lib/remoteagents/lan/pending', '/var/lib/remoteagents/proxy-out/pending',
        '/var/lib/remoteagents/port-leak/pending')), 'Сначала завершите прежнее изменение сети.')
    data = candidate(engine)  # Resolve secrets/conflicts before installing anything.
    was_active = s.active('sing-box')
    was_enabled = s.run(['systemctl', 'is-enabled', '--quiet', 'sing-box'], check=False).returncode == 0
    try:
        install_packages(engine)
        proxy = engine_module('proxy_out')
        p = engine.config['proxyOut']
        auth = (p.get('login', ''), engine.secret(p['password'], 'proxy-out-password') if p.get('password') else '')
        probe = s.run(['curl', '--disable', '--fail', '--silent', '--max-time', '15', '-K', '-', p['checkUrl']],
                      input=proxy.curl_config(proxy.proxy_url(p['type'], p['server'], p['port']), auth))
        _require(probe.stdout.strip() == p['exitIp'], 'Прокси до включения TUN не дал ожидаемый exitIp.')
        version = s.run(['sing-box', 'version']).stdout
        match = re.search(r'version (\d+)\.(\d+)', version)
        if match and tuple(map(int, match.groups())) >= (1, 14):
            data['inbounds'][0]['dns_mode'] = 'disabled'
        # A package may ship a sample config. It did not exist before this apply,
        # so rollback removes it too; a clean retry must not mistake it for owner config.
        engine.install_code()
        recovery = ('[Unit]\nDescription=Recover unconfirmed server network\nDefaultDependencies=no\n'
                    'After=local-fs.target\nBefore=sing-box.service remoteagents-network-guard.service\n'
                    '[Service]\nType=oneshot\nExecStart=/usr/bin/python3 -I ' + BIN + ' recover\n'
                    '[Install]\nWantedBy=multi-user.target\n')
        s.write('/etc/systemd/system/remoteagents-base-network-recover.service', recovery, 0o644)
        s.run(['systemctl', 'daemon-reload'], change=True)
        s.run(['systemctl', 'enable', 'remoteagents-base-network-recover.service'], change=True)
        with s.private_file(json.dumps(data)) as file:
            s.run(['sing-box', 'check', '-c', file])
        state = {'config': None, 'active': was_active, 'enabled': was_enabled,
                 'inboundsHash': hashlib.sha256(engine.secret(engine.config['serverNetwork']['inbounds'], 'server-inbounds').encode()).hexdigest() if engine.config['serverNetwork'].get('inbounds') else None,
                 'candidateHash': hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest(),
                 'tables': {}, 'rules': {}, 'desired': engine.config.get('serverNetwork'),
                 'proxy': {k: v for k, v in engine.config['proxyOut'].items() if k not in ('password', 'login', 'hint')}}
        for table in ('remoteagents_inbound', 'remoteagents_ipv6'):
            r = s.run(['nft', 'list', 'table', 'inet', table], check=False)
            state['tables'][table] = r.stdout if r.returncode == 0 else None
        for family in ('-4', '-6'):
            state['rules'][family] = engine.reply_rule(family)
        s.write(STATE + '/state.json', json.dumps(state))
        try:
            s.run(['systemd-run', '--quiet', '--unit=' + TIMER, '--on-active=5m',
                   '--timer-property=AccuracySec=1s', '/usr/bin/python3', '-I', BIN, 'rollback'], change=True)
        except Exception:
            shutil.rmtree(s.path(STATE))
            raise
    except Exception:
        # The package may already have installed/enabled its sample config.
        # A failed proxy/check/preparation must remain retryable and must not
        # leave that sample running. No network guard/TUN mutation has begun.
        if not was_active:
            s.run(['systemctl', 'stop', 'sing-box'], check=False, change=True)
        s.path('/etc/sing-box/config.json').unlink(missing_ok=True)
        s.run(['systemctl', 'enable' if was_enabled else 'disable', 'sing-box'], check=False, change=True)
        raise
    try:
        engine.network_guard()  # ct mark + rule 8990 precede the first TUN packet.
        s.write('/etc/sing-box/config.json', json.dumps(data) + '\n')
        s.run(['systemctl', 'enable', '--now', 'sing-box'], change=True)
        s.run(['systemctl', 'restart', 'sing-box'], change=True)
        # systemctl start returns before sing-box finishes creating policy rules.
        deadline = time.monotonic() + 30
        while True:
            ok, reason = engine.egress_check()
            if ok or time.monotonic() >= deadline:
                break
            time.sleep(0.5)
        _require(ok, reason)
    except Exception:
        rollback(s)
        raise


def rollback(s, boot=False):
    state = s.read(STATE + '/state.json')
    if not state:
        return
    if not boot:
        s.run(['systemctl', 'stop', 'sing-box'], change=True)
    old = state['config']
    if old:
        s.write('/etc/sing-box/config.json', old['text'], old['mode'])
    else:
        s.path('/etc/sing-box/config.json').unlink(missing_ok=True)
    for name, text in state['tables'].items():
        exists = s.run(['nft', 'list', 'table', 'inet', name], check=False).returncode == 0
        script = ('delete table inet ' + name + '\n' if exists else '') + (text or '')
        if script:
            s.run(['nft', '-f', '-'], input=script, change=True)
    for family, existed in state['rules'].items():
        if not existed:
            s.run(['ip', family, 'rule', 'del', 'pref', '8990', 'fwmark', '0x5241', 'lookup', 'main'], check=False, change=True)
    s.run(['systemctl', 'enable' if state['enabled'] else 'disable', 'sing-box'], change=True)
    if state['active'] and not boot:
        s.run(['systemctl', 'start', 'sing-box'], change=True)
    shutil.rmtree(s.path(STATE))
    s.run(['systemctl', 'stop', TIMER + '.timer'], check=False)


def confirm(engine):
    state = engine.s.read(STATE + '/state.json')
    _require(state and state['desired'] == engine.config.get('serverNetwork') and
             state['proxy'] == {k: v for k, v in engine.config['proxyOut'].items() if k not in ('password', 'login', 'hint')},
             'Параметры ожидающего развёртывания изменились; дождитесь отката.')
    ok, reason = engine.egress_check()
    _require(ok, reason)
    protected, reason = engine.inbound_check()
    _require(protected, reason)
    _require(engine.proxy_matches(engine.config['proxyOut']), 'Прокси изменился до подтверждения.')
    _require(hashlib.sha256(json.dumps(engine.s.read('/etc/sing-box/config.json'), sort_keys=True).encode()).hexdigest() == state['candidateHash'],
             'Конфиг sing-box изменился до подтверждения; таймер сохранён.')
    if engine.config['serverNetwork'].get('inbounds'):
        _require(hashlib.sha256(engine.secret(engine.config['serverNetwork']['inbounds'], 'server-inbounds').encode()).hexdigest() == state['inboundsHash'],
                 'Секрет входящих изменился до подтверждения; таймер сохранён.')
    engine.check_ssh(None)
    engine.save_receipt('base-network', {'managed': True})
    shutil.rmtree(engine.s.path(STATE))
    engine.s.run(['systemctl', 'stop', TIMER + '.timer'], check=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['rollback', 'recover'])
    args = parser.parse_args()
    _require(os.geteuid() == 0, 'Нужен root.')
    s = engine_module('server_apply').System()
    with s.network_lock():
        rollback(s, boot=args.command == 'recover')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('Ошибка: откат базовой сети не выполнен; детали скрыты.')
