#!/usr/bin/env python3
"""Constrain destination AND source port bypasses to the server TUN inbound."""
import argparse
import contextlib
import fcntl
import importlib.util
import json
import ipaddress
import os
from pathlib import Path
import shutil
import sys
import time

# Explicit local module loading works with python -I, including installed copies.
spec = importlib.util.spec_from_file_location('lan_vpn', Path(__file__).with_name('lan_vpn.py'))
lan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lan)
STATE = Path('/var/lib/remoteagents/port-leak')
BIN = Path('/usr/local/lib/remoteagents/port-leak')
PORTS = {22, 3389, 37091}


def repair(config):
    result = json.loads(json.dumps(config))
    rules, changes = [], []
    for index, original in enumerate(config.get('route', {}).get('rules', [])):
        rule = dict(original)
        inbound = rule.get('inbound') or []
        inbound = inbound if isinstance(inbound, list) else [inbound]
        if rule.get('outbound') != 'direct-out' or inbound == ['tun-in']:
            rules.append(rule)
            continue
        # Nested and inverted matches cannot be split using ordinary AND semantics.
        lan.require(rule.get('type') != 'logical' and not rule.get('invert'),
                    'Логическое/инвертированное direct-out требует ручной проверки.')
        # A later public-address direct exception can bypass fixed port rules.
        # Preserve all destination values, but reserve this exception for server
        # traffic too. Never put its addresses into diff/log metadata.
        if 'ip_cidr' in rule:
            cidrs = rule['ip_cidr'] if isinstance(rule['ip_cidr'], list) else [rule['ip_cidr']]
            try:
                nets = [ipaddress.ip_network(v, strict=False) for v in cidrs]
            except ValueError:
                raise lan.Error('Неподдерживаемый формат ip_cidr.') from None
            private = list(lan.PRIVATE) + [ipaddress.ip_network('fc00::/7')]
            if any(not any(n.version == p.version and n.subnet_of(p) for p in private) for n in nets):
                rule['inbound'] = ['tun-in']
                if not inbound or 'tun-in' in inbound:
                    rules.append(rule)
                changes.append({'ruleIndex': index, 'selector': 'ip_cidr', 'addressCount': len(nets), 'inbound': ['tun-in'], 'removed': bool(inbound and 'tun-in' not in inbound)})
                continue
        selectors = [k for k in ('port', 'source_port') if k in rule]
        if len(selectors) != 1:
            # Complex combined predicates need a separate review.
            lan.require(not selectors, 'Сложное правило direct-out требует ручной проверки.')
            rules.append(rule)
            continue
        key = selectors[0]
        values = rule[key] if isinstance(rule[key], list) else [rule[key]]
        lan.require(all(type(v) is int for v in values), 'Неподдерживаемый формат port/source_port.')
        affected = sorted(set(values) & PORTS)
        if not affected:
            rules.append(rule)
            continue
        limited = dict(rule, inbound=['tun-in'])
        limited[key] = affected
        if not inbound or 'tun-in' in inbound:
            rules.append(limited)
        rest = [v for v in values if v not in PORTS]
        if rest:
            remaining = dict(rule)
            remaining[key] = rest
            rules.append(remaining)
        changes.append({'ruleIndex': index, 'selector': key, 'ports': affected, 'inbound': ['tun-in'], 'removed': bool(inbound and 'tun-in' not in inbound)})
    lan.require(config.get('route', {}).get('final') == 'proxy-out', 'Ожидается final=proxy-out.')
    lan.require(any(i.get('tag') == 'tun-in' and i.get('type') == 'tun' for i in config.get('inbounds', [])),
                'Нет tun-in.')
    result['route']['rules'] = rules
    return result, changes


def show_diff(changes, reverse=False):
    for change in changes:
        old = {change['selector']: change.get('ports', '<addresses hidden>'), 'outbound': 'direct-out', 'inbound': '(not server-only)'}
        new = {'removed': True} if change.get('removed') else dict(old, inbound=['tun-in'])
        print('@@ route.rules[' + str(change['ruleIndex']) + '] (семантический diff) @@', flush=True)
        print('- ' + json.dumps(new if reverse else old), flush=True)
        print('+ ' + json.dumps(old if reverse else new), flush=True)


def clear_timer():
    lan.run(['systemctl', 'stop', 'remoteagents-port-leak-rollback.timer'], check=False)
    lan.run(['systemctl', 'reset-failed', 'remoteagents-port-leak-rollback.service'], check=False)


def rollback(boot=False):
    pending = STATE / 'pending'
    lan.require(pending.exists(), 'Нет ожидающего отката port-leak.')
    backup, meta = pending / 'sing-box.json', lan.read(pending / 'meta.json')
    lan.run(['sing-box', 'check', '-c', backup])
    _, changes = repair(lan.read(backup))
    show_diff(changes, reverse=True)
    lan.atomic(lan.SB, backup.read_text(), meta['mode'])
    os.chown(lan.SB, meta['uid'], meta['gid'])
    if not boot:
        lan.run(['systemctl', 'restart', 'sing-box'])
    shutil.rmtree(pending)
    clear_timer()
    lan.event('portleak', 'rollback: sing-box восстановлен')
    print('Откат port-leak выполнен.')


def install():
    BIN.mkdir(mode=0o755, parents=True, exist_ok=True)
    here = Path(__file__).resolve().parent
    for name in ('close-port-leak.sh', 'close_port_leak.py', 'lan_vpn.py'):
        if (here / name) != (BIN / name):
            lan.atomic(BIN / name, (here / name).read_text(), 0o755 if name.endswith('.sh') else 0o644)
    unit = '''[Unit]
Description=Recover unconfirmed port leak change after reboot
DefaultDependencies=no
After=local-fs.target
Before=sing-box.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/remoteagents/port-leak/close-port-leak.sh _recover
[Install]
WantedBy=multi-user.target
'''
    path = Path('/etc/systemd/system/remoteagents-port-leak-recover.service')
    lan.atomic(path, unit, 0o644)
    lan.run(['systemd-analyze', 'verify', path])
    lan.run(['systemctl', 'daemon-reload'])
    lan.run(['systemctl', 'enable', path.name])


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description='Fix port bypasses; owner executes and confirms.')
    parser.add_argument('command', nargs='?', default='apply', choices=['apply', 'confirm', 'rollback', '_recover'])
    parser.add_argument('--rollback', action='store_true', help='Compatibility alias for rollback')
    parser.add_argument('--ip-check-url')
    parser.add_argument('--ssh-checked', action='store_true')
    parser.add_argument('--vless-checked', action='store_true')
    args = parser.parse_args()
    lan.require(os.geteuid() == 0, 'Нужен sudo; агент не применяет изменения.')
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    pending = STATE / 'pending'
    command = 'rollback' if args.rollback else args.command
    with open(STATE.parent / 'network.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if command in ('rollback', '_recover'):
            if command == 'rollback' or pending.exists():
                rollback(command == '_recover')
            return
        if command == 'confirm':
            lan.require(pending.exists(), 'Нет ожидающего подтверждения port-leak.')
            lan.require(args.ssh_checked and args.vless_checked,
                        'Нужны --ssh-checked и --vless-checked после нового SSH и теста клиента VLESS.')
            meta = lan.read(pending / 'meta.json')
            lan.require(lan.baseline(meta['url']) == meta['baseline'], 'Выходной IP изменился.')
            lan.run(['sing-box', 'check', '-c', lan.SB])
            lan.require(lan.run(['systemctl', 'is-active', '--quiet', 'sing-box'], check=False).returncode == 0,
                        'sing-box не активен.')
            shutil.rmtree(pending)
            clear_timer()
            lan.event('portleak', 'confirmed: proxy-out проверен; SSH/VLESS проверены владельцем', True)
            print('Port-leak подтверждён, таймер отката снят.')
            return
        lan.require(not pending.exists() and not (lan.STATE / 'pending').exists(),
                    'Сначала подтвердите или откатите предыдущее изменение сети.')
        lan.require(args.ip_check_url, 'Нужен --ip-check-url (HTTPS, только IP в ответе).')
        before = lan.read(lan.SB)
        after, changes = repair(before)
        if not changes:
            lan.run(['sing-box', 'check', '-c', lan.SB])
            print('Подходящих неограниченных port/source_port правил нет; изменений нет.')
            return
        # Exact semantic diff without any unrelated rules or secret context.
        print('Diff /etc/sing-box/config.json: только перечисленные port/source_port правила:', flush=True)
        show_diff(changes)
        candidate = STATE / 'candidate.json'
        lan.save(candidate, after)
        lan.run(['sing-box', 'check', '-c', candidate])
        ip_hash = lan.baseline(args.ip_check_url)
        install()
        pending.mkdir(mode=0o700)
        st = lan.SB.stat()
        shutil.copy2(lan.SB, pending / 'sing-box.json')
        os.chmod(pending / 'sing-box.json', 0o600)
        lan.save(pending / 'meta.json', {'uid': st.st_uid, 'gid': st.st_gid, 'mode': st.st_mode & 0o777,
                                        'url': args.ip_check_url, 'baseline': ip_hash, 'created': time.time()})
        try:
            lan.run(['systemd-run', '--quiet', '--unit=remoteagents-port-leak-rollback', '--on-active=5m',
                     '--timer-property=AccuracySec=1s', BIN / 'close-port-leak.sh', 'rollback'])
        except Exception:
            shutil.rmtree(pending)
            raise
        try:
            lan.apply_singbox(candidate)
            lan.require(lan.baseline(args.ip_check_url) == ip_hash, 'Выходной IP изменился.')
            lan.event('portleak', 'pending: port/source_port ограничены tun-in; нужен confirm')
        except Exception:
            rollback()
            raise
        print('Применено с автооткатом 5 минут. Проверьте новый SSH и IP клиента VLESS, затем confirm.')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        with contextlib.suppress(Exception):
            if os.geteuid() == 0:
                lan.event('portleak', 'error: команда не выполнена; диагностический вывод скрыт')
        print('Ошибка: ' + (str(exc) if isinstance(exc, lan.Error) else 'Ошибка файла/команды; детали скрыты.'), file=sys.stderr)
        sys.exit(1)
