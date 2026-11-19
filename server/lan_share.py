#!/usr/bin/env python3
"""Destination-scoped channel egress, reconciled by server_apply, never a VPN client.

Only the repository's known termination configs are supported. Pure generators do
no DNS/network IO. The normal route/final remains in force for all other traffic.
"""
import copy
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import sys

STATE = '/var/lib/remoteagents/lan-share/pending'
MANIFEST = '/etc/remoteagents/server-apply/lan-share.json'
BIN = '/usr/local/lib/remoteagents/server/lan_share.py'
TIMER = 'remoteagents-lan-share-rollback'
TARGETS = (('/etc/sing-box/config.json', 'sing-box', 'singbox'),
           ('/usr/local/etc/remoteagents-happ/config.json', 'remoteagents-happ', 'xray'))
DNS_TAG = 'lan-share-system-dns'
LAN_NAME = re.compile(r'[a-z][a-z0-9]{0,6}\Z')  # как lan_vpn.NAME: интерфейс tun-lan-ИМЯ


def lan_tag(name):
    return 'lan-' + name + '-out'


def lan_outbound(name):
    # auto_detect_interface привязывает direct-out к внешнему интерфейсу;
    # тогда ядро не может взять маршрут таблицы ЛВС и даёт no route to host.
    return {'type': 'direct', 'tag': lan_tag(name), 'bind_interface': 'tun-lan-' + name}


class Error(Exception):
    pass


def require(ok, message):
    if not ok:
        raise Error(message)


def cidr(text):
    try:
        n = ipaddress.IPv4Network(text)
        require(str(n) == text and any(n.subnet_of(ipaddress.IPv4Network(p)) for p in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')),
                'share.subnets: нужна каноническая подсеть RFC1918.')
        return n
    except ValueError:
        raise Error('share.subnets: неверный IPv4 CIDR.') from None


def domain(text):
    name = text[2:] if text.startswith('*.') else text
    require(len(name) <= 253 and '.' in name and all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label) for label in name.split('.')),
            'share.domains: нужно DNS-имя или *.домен.')
    try:
        ipaddress.ip_address(name)
    except ValueError:
        return text.lower()
    raise Error('share.domains: IP задаётся через subnets.')


def policy(config):
    result = dict(subnets=[], domains=[], forwards=[], lanSubnets=[], lans=[])
    for item in config.get('lan', []):
        share = item.get('share', {})
        for text in share.get('subnets', []):
            cidr(text)
            result['subnets'].append(text)
        result['lanSubnets'] += item.get('subnets', []) + share.get('subnets', [])
        result['domains'] += [domain(d) for d in share.get('domains', [])]
        names = set()
        for f in share.get('forwards', []):
            require(f['name'] not in names, 'share.forwards: имена повторяются.')
            names.add(f['name'])
            try:
                ipaddress.ip_address(f['host'])
            except ValueError:
                require(not f['host'].startswith('*.'), 'forward.host: нужен точный хост.')
                domain(f['host'])
            else:
                cidr(f['host'] + '/32')
            result['forwards'].append(dict(host=f['host'].lower(), port=f['port']))
        if any(share.get(k) for k in ('subnets', 'domains', 'forwards')):
            name = item.get('name', '')
            require(isinstance(name, str) and LAN_NAME.fullmatch(name),
                    'lan.name: для доступа с ПК имя должно совпадать с ЛВС сервера ([a-z][a-z0-9]{0,6}).')
            host = item.get('testHost', item.get('host', ''))
            port = item.get('testPort', item.get('port', 22))
            if not host and share.get('forwards'):
                host, port = share['forwards'][0]['host'], share['forwards'][0]['port']
            allowed = any(f['host'] == host and f['port'] == port for f in share.get('forwards', []))
            try:
                allowed |= any(ipaddress.ip_address(host) in cidr(n) for n in share.get('subnets', []))
            except ValueError:
                pass
            allowed |= any(host.lower().endswith(d[1:].lower()) if d.startswith('*.') else host.lower() == d.lower() for d in share.get('domains', []))
            require(host and allowed, 'lan.share: нужен разрешённый testHost/testPort или первый forward.')
            result['lans'].append(dict(
                name=name,
                subnets=sorted(set(share.get('subnets', []))),
                lanSubnets=sorted(set(item.get('subnets', []) + share.get('subnets', []))),
                domains=sorted(set(domain(d) for d in share.get('domains', []))),
                forwards=[dict(host=f['host'].lower(), port=f['port']) for f in share.get('forwards', [])]))
    for key in ('subnets', 'domains', 'lanSubnets'):
        result[key] = sorted(set(result[key]))
    result['lans'].sort(key=lambda x: x['name'])
    return result


def enabled(p):
    return any(p[k] for k in ('subnets', 'domains', 'forwards'))


def domain_match(d):
    return {'domain_regex': ['^.+\\.' + re.escape(d[2:]) + '$']} if d.startswith('*.') else {'domain': [d]}


def generate(config, p, kind, previous=None):
    """Remove only the recorded owned prefix; preserve the rest byte-for-value."""
    result = copy.deepcopy(config)
    route = result.setdefault('route' if kind == 'singbox' else 'routing', {})
    rules = route.setdefault('rules', [])
    previous = previous or {}
    old = previous.get('rules', [])
    require(not old or rules[:len(old)] == old, 'Управляемые правила share изменены вручную; требуется сверка.')
    del rules[:len(old)]
    if previous.get('dns'):
        servers = result.get('dns', {}).get('servers', [])
        require(previous['dns'] in servers, 'DNS share изменён вручную.')
        servers.remove(previous['dns'])
        if previous.get('createdDns') and result.get('dns') == {'servers': []}:
            del result['dns']
    for out in previous.get('outbounds', []):
        outs = result.get('outbounds', [])
        require(out in outs, 'Управляемый выход share изменён вручную; требуется сверка.')
        outs.remove(out)
    added, dns, created_dns, owned = [], None, False, []
    if enabled(p) and kind == 'singbox':
        tags = [i['tag'] for i in result.get('inbounds', []) if i.get('type') in ('vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria2', 'tuic', 'hysteria') and i.get('tag')]
        require(tags, 'Нет именованных серверных входов канала sing-box.')
        direct = next((o['tag'] for o in result.get('outbounds', []) if o.get('type') == 'direct' and o.get('tag') == 'direct-out'), None)
        require(direct, 'Нет штатного direct-out sing-box; чужой выход не подменяется.')
        normal = route.get('final')
        require(normal, 'Нужен явный обычный route.final сервера.')
        def add(match, outbound=direct):
            # Logical rules accept matchers inside rules, not at the top level.
            if match.get('type') == 'logical':
                match = copy.deepcopy(match)
                match['rules'].insert(0, {'inbound': tags})
                added.append(dict(**match, action='route', outbound=outbound))
            else:
                added.append(dict(inbound=tags, **match, action='route', outbound=outbound))
        domains = list(p['domains']) + [f['host'] for f in p['forwards'] if not re.fullmatch(r'[0-9.]+', f['host'])]
        if domains:
            created_dns = 'dns' not in result
            servers = result.setdefault('dns', {}).setdefault('servers', [])
            require(not any(s.get('tag') == DNS_TAG for s in servers if isinstance(s, dict)), 'Имя DNS share уже занято.')
            dns = dict(type='local', tag=DNS_TAG)
            servers.append(dns)
        for lan in p['lans']:
            out = lan_outbound(lan['name'])
            outs = result.setdefault('outbounds', [])
            require(not any(o.get('tag') == out['tag'] for o in outs), 'Тег ' + out['tag'] + ' уже занят чужим выходом.')
            outs.append(out)
            owned.append(out)
            egress = out['tag']
            if lan['subnets']:
                add({'ip_cidr': lan['subnets']}, egress)
            for d in lan['domains']:
                match = domain_match(d)
                added.append(dict(inbound=tags, **match, action='resolve', server=DNS_TAG, strategy='ipv4_only'))
                if lan['lanSubnets']:
                    add({'type': 'logical', 'mode': 'and', 'rules': [match, {'ip_cidr': lan['lanSubnets']}]}, egress)
                add({'type': 'logical', 'mode': 'and', 'rules': [match, {'ip_is_private': True, 'invert': True}]}, normal)
            for f in lan['forwards']:
                match = {'ip_cidr': [f['host'] + '/32']} if re.fullmatch(r'[0-9.]+', f['host']) else {'domain': [f['host']]}
                if 'domain' in match:
                    added.append(dict(inbound=tags, **match, port=[f['port']], action='resolve', server=DNS_TAG, strategy='ipv4_only'))
                    if lan['lanSubnets']:
                        add({'type': 'logical', 'mode': 'and', 'rules': [match, {'ip_cidr': lan['lanSubnets']}, {'port': [f['port']]}]}, egress)
                    add({'type': 'logical', 'mode': 'and', 'rules': [match, {'ip_is_private': True, 'invert': True}, {'port': [f['port']]}]}, normal)
                else:
                    add(dict(match, port=[f['port']]), egress)
    elif enabled(p):
        # This installer has a single authenticated VLESS terminator. Do not grant
        # a bypass to an unrelated, anonymous inbound in a hand-written config.
        require(result.get('inbounds') and all(i.get('protocol') == 'vless' and i.get('settings', {}).get('clients') for i in result['inbounds']), 'Неподдержанный вход Xray для share.')
        direct = next((o.get('tag') for o in result.get('outbounds', []) if o.get('protocol') == 'freedom' and o.get('tag')), None)
        require(direct, 'Нет обычного freedom выхода Xray.')
        if p['subnets']:
            added.append(dict(type='field', ip=p['subnets'], outboundTag=direct))
        for d in p['domains']:
            value = 'regexp:^.+\\.' + re.escape(d[2:]) + '$' if d.startswith('*.') else 'full:' + d
            added.append(dict(type='field', domain=[value], outboundTag=direct))
        for f in p['forwards']:
            match = {'ip': [f['host'] + '/32']} if re.fullmatch(r'[0-9.]+', f['host']) else {'domain': ['full:' + f['host']]}
            added.append(dict(type='field', **match, port=str(f['port']), outboundTag=direct))
    route['rules'] = added + rules
    return result, copy.deepcopy(dict(rules=added, dns=dns, createdDns=created_dns, outbounds=owned))


CONDITIONAL = {'domain', 'domain_suffix', 'domain_keyword', 'domain_regex', 'port', 'port_range', 'source_ip_cidr',
               'source_port', 'protocol', 'network', 'rule_set', 'type', 'invert', 'auth_user', 'process_name'}


def egress_issues(config, lans):
    """Проверка без IO: каждая подсеть канала должна идти в свой tun-lan-ИМЯ."""
    issues = []
    outs = {o.get('tag'): o for o in config.get('outbounds', []) if isinstance(o, dict)}
    rules = config.get('route', {}).get('rules', [])
    channel = {i['tag'] for i in config.get('inbounds', []) if i.get('type') in
               ('vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria2', 'tuic', 'hysteria') and i.get('tag')}
    for lan in lans:
        want = lan_outbound(lan['name'])
        for text in lan['subnets']:
            net = ipaddress.IPv4Network(text)
            decider = None
            for r in rules:
                if r.get('action', 'route') != 'route' or set(r).intersection(CONDITIONAL):
                    continue
                if 'inbound' in r and not channel.intersection(r['inbound'] if isinstance(r['inbound'], list) else [r['inbound']]):
                    continue
                cidrs = r.get('ip_cidr', [])
                cidrs = cidrs if isinstance(cidrs, list) else [cidrs]
                if any(net.subnet_of(ipaddress.IPv4Network(c, strict=False)) for c in cidrs if ':' not in c) or r.get('ip_is_private') is True:
                    decider = r
                    break
            if decider is None:
                issues.append(lan['name'] + ' ' + text + ': нет правила, уходит в route.final')
                continue
            got = outs.get(decider.get('outbound'))
            if decider.get('outbound') != want['tag'] or not got or got.get('type') != 'direct' or got.get('bind_interface') != want['bind_interface']:
                issues.append(lan['name'] + ' ' + text + ': правило ведёт в ' + str(decider.get('outbound')) +
                              ', нужен выход ' + want['tag'] + ' с bind_interface ' + want['bind_interface'])
    return issues


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def rollback(s, boot=False):
    with s.network_lock():
        state = s.read(STATE + '/state.json')
        if not state:
            return
        for path, old in state['files'].items():
            s.write(path, old['text'], old['mode'])
            if s.root == Path('/'):
                os.chown(s.path(path), old['uid'], old['gid'])
        if state['manifest'] is None:
            s.path(MANIFEST).unlink(missing_ok=True)
        else:
            s.write(MANIFEST, json.dumps(state['manifest']))
        if not boot:
            for unit in state['units']:
                s.run(['systemctl', 'restart', unit], change=True)
        shutil.rmtree(s.path(STATE))
        if not boot:
            s.run(['systemctl', 'stop', TIMER + '.timer'], check=False)
            s.run(['systemctl', 'reset-failed', TIMER + '.service'], check=False)


def _reconcile(e, apply, transaction):
    s, p = e.s, policy(e.config)
    manifest = s.read(MANIFEST, {})
    pending = s.read(STATE + '/state.json')
    # The periodic reconcile never starts or re-arms a share transaction (the 17-18.11 loop:
    # rollback timer undoes it, reconcile applies again). Only an owner apply/confirm may.
    periodic = getattr(e, 'periodic', False)
    if periodic:
        apply = False
    if pending and periodic:
        print('lan-share pending ждёт confirm или отката', file=sys.stderr, flush=True)
        return e.row('lanShare', 'ready', 'lan-share pending ждёт confirm или отката; периодический reconcile ничего не применяет')
    if pending:
        require(pending['policyHash'] == digest(p), 'share изменён до confirm; дождитесь отката.')
        if apply and e.ssh_checked:
            with s.network_lock():
                for path, candidate_hash in pending['candidateHashes'].items():
                    require(digest(s.read(path)) == candidate_hash, 'Конфиг канала изменился до confirm.')
                e.check_ssh(None)
                shutil.rmtree(s.path(STATE))
                s.run(['systemctl', 'stop', TIMER + '.timer'], check=False)
            return e.row('lanShare', 'ready', 'Доступ с ПК: правила подтверждены новым SSH')
        return e.row('lanShare', 'pending', 'Доступ с ПК: требуется новое SSH перед подтверждением')
    if not enabled(p) and not manifest:
        return e.row('lanShare', 'ready', 'Доступ с ПК не задан; правил канала нет')
    # Use the LAN manager's current discovered routes, not a separate route list.
    for item in e.config.get('lan', []):
        actual = s.read('/etc/remoteagents/lan/' + item['name'] + '/config.json', {})
        actual_subnets = list(actual.get('subnets', actual.get('static', [])))
        p['lanSubnets'] += actual_subnets
        subnet_file = s.path('/etc/remoteagents/lan/' + item['name'] + '/subnets')
        if subnet_file.is_file():
            discovered = [str(cidr(n)) for n in subnet_file.read_text().split()]
            p['lanSubnets'] += discovered
            actual_subnets += discovered
        for lan in p['lans']:
            if lan['name'] == item['name']:
                lan['lanSubnets'] = sorted(set(lan['lanSubnets'] + actual_subnets))
        if apply:
            networks = [cidr(n) for n in actual_subnets]
            for subnet in item.get('share', {}).get('subnets', []):
                require(any(cidr(subnet).subnet_of(n) for n in networks), 'share.subnets выходит за подтверждённые маршруты ЛВС.')
            for forward in item.get('share', {}).get('forwards', []):
                if re.fullmatch(r'[0-9.]+', forward['host']):
                    require(any(ipaddress.ip_address(forward['host']) in n for n in networks), 'forward.host не входит в подтверждённую ЛВС.')
    p['lanSubnets'] = sorted(set(p['lanSubnets']))
    changes, records, units, expected = {}, {}, [], {}
    for path, unit, kind in TARGETS:
        file = s.path(path)
        if not file.exists():
            require(path not in manifest, 'Управляемый конфиг канала пропал.')
            continue
        # A stopped terminator we never managed carries no channel traffic; leave it alone.
        if path not in manifest and not s.active(unit):
            continue
        # Main system sing-box may have only a TUN; that is not a channel terminator.
        current = s.read(path)
        if kind == 'singbox' and not any(i.get('type') in ('vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria2', 'tuic', 'hysteria') for i in current.get('inbounds', [])) and path not in manifest:
            continue
        generated, record = generate(current, p, kind, manifest.get(path))
        if kind == 'singbox' and enabled(p):
            issues = egress_issues(generated, p['lans'])
            require(not issues, 'Маршрут ЛВС в sing-box неверен: ' + '; '.join(issues))
        records[path] = record
        if generated != current:
            changes[path] = (generated, unit, kind)
            expected[path] = digest(current)
    require(records or not enabled(p), 'Не найден поддерживаемый серверный вход канала.')
    if not changes:
        return e.row('lanShare', 'ready', 'Доступ с ПК: назначения разрешены; остальные правила сохранены')
    if not apply:
        return e.row('lanShare', 'change', 'Нужно обновить разрешённые назначения канала' +
                     ('; периодический reconcile их не применяет — нужен apply владельца' if periodic else ''))
    # Do not enable bypasses for an unverified LAN. Its manager proves route get,
    # interface tun-lan-NAME and the host TCP probe before this part is reached.
    for item in e.config.get('lan', []):
        if any(item.get('share', {}).get(k) for k in ('subnets', 'domains', 'forwards')):
            require(any(r['part'] == 'lan:' + item['name'] and r['state'] == 'ready' for r in e.rows), 'Сначала подтвердите ЛВС на сервере.')
    e.install_code()
    with s.network_lock():
        require(not any(s.path(path).exists() for path in (STATE, '/var/lib/remoteagents/base-network/pending', '/var/lib/remoteagents/lan/pending', '/var/lib/remoteagents/proxy-out/pending', '/var/lib/remoteagents/port-leak/pending')), 'Сначала завершите прежнее изменение сети.')
        files = {}
        for path, (data, unit, kind) in changes.items():
            require(digest(s.read(path)) == expected[path], 'Конфиг канала изменился во время подготовки.')
            require(s.active(unit), 'Серверный вход канала не запущен.')
            with s.private_file(json.dumps(data)) as temp:
                args = ['sing-box', 'check', '-c', temp] if kind == 'singbox' else ['/usr/local/bin/remoteagents-xray', 'run', '-test', '-config', temp]
                s.run(args)
            file = s.path(path); st = file.stat()
            files[path] = dict(text=file.read_text(), mode=st.st_mode & 0o777, uid=st.st_uid, gid=st.st_gid)
            units.append(unit)
        recovery = '[Unit]\nDescription=Recover unconfirmed LAN share\nDefaultDependencies=no\nAfter=local-fs.target\nBefore=sing-box.service remoteagents-happ.service\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 -I ' + BIN + ' recover\n[Install]\nWantedBy=multi-user.target\n'
        s.write('/etc/systemd/system/remoteagents-lan-share-recover.service', recovery, 0o644)
        s.run(['systemctl', 'daemon-reload'], change=True)
        s.run(['systemctl', 'enable', 'remoteagents-lan-share-recover.service'], change=True)
        state = dict(files=files, units=units, manifest=manifest or None, policyHash=digest(policy(e.config)), candidateHashes={path: digest(row[0]) for path, row in changes.items()})
        s.write(STATE + '/state.json', json.dumps(state))
        transaction['created'] = True
        try:
            s.run(['systemd-run', '--quiet', '--unit=' + TIMER, '--on-active=5m', '--timer-property=AccuracySec=1s', '/usr/bin/python3', '-I', BIN, 'rollback'], change=True)
        except Exception:
            shutil.rmtree(s.path(STATE))
            raise
        try:
            for path, (data, unit, _) in changes.items():
                s.write(path, json.dumps(data) + '\n', files[path]['mode'])
                if s.root == Path('/'):
                    os.chown(s.path(path), files[path]['uid'], files[path]['gid'])
                s.run(['systemctl', 'restart', unit], change=True)
                require(s.active(unit), 'Серверный вход не запустился; нужен откат share.')
            s.write(MANIFEST, json.dumps(records) if enabled(p) else '{}')
        except Exception:
            # Outside this lock, rollback uses the same common lock.
            raise
    return e.row('lanShare', 'pending', 'Доступ с ПК: применено с откатом через 5 минут; нужно новое SSH')


def reconcile(e, apply):
    transaction = {}
    try:
        return _reconcile(e, apply, transaction)
    except Exception:
        if transaction.get('created') and e.s.path(STATE).exists():
            rollback(e.s)
        raise


def check(argv, path='/etc/sing-box/config.json'):
    """lan_share.py check ИМЯ CIDR [CIDR...] — только чтение, 0 = верно, 1 = проблемы."""
    require(len(argv) >= 2 and LAN_NAME.fullmatch(argv[0]), 'Использование: lan_share.py check ИМЯ CIDR [CIDR...]')
    subnets = [str(cidr(c)) for c in argv[1:]]
    issues = egress_issues(json.loads(Path(path).read_text()), [dict(name=argv[0], subnets=subnets)])
    print('\n'.join(issues) if issues else 'OK: подсети ' + ', '.join(subnets) + ' ведут в ' + lan_tag(argv[0]))
    return 1 if issues else 0


def main():
    import importlib.util
    import sys
    if sys.argv[1:2] == ['check']:
        raise SystemExit(check(sys.argv[2:]))
    spec = importlib.util.spec_from_file_location('server_apply_share', Path(__file__).with_name('server_apply.py'))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    require(os.geteuid() == 0, 'Нужен root.')
    rollback(m.System(), boot=sys.argv[1:] == ['recover'])


if __name__ == '__main__':
    main()
