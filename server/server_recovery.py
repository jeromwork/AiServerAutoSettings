#!/usr/bin/env python3
"""Restore only the last externally confirmed managed network, never confirm changes.

The root-only envelope is written after a successful apply. No live credentials or
arbitrary paths are scraped; secrets come from the application's resolved config.
"""
import json
import os
import re
from pathlib import Path
import time

ENVELOPE = '/etc/remoteagents/server-apply/recovery.json'
UNIT = 'remoteagents-reconcile'
MAX_ENVELOPE = 32 * 1024 * 1024
PENDING = ('/var/lib/remoteagents/base-network/pending', '/var/lib/remoteagents/lan/pending',
           '/var/lib/remoteagents/proxy-out/pending', '/var/lib/remoteagents/port-leak/pending')


def units():
    return {
        '/etc/systemd/system/' + UNIT + '.service': '[Unit]\nDescription=Reconcile confirmed RemoteAgents server\nWants=network-online.target\nAfter=network-online.target remoteagents-base-network-recover.service remoteagents-lan-recover.service\n[Service]\nType=oneshot\nUMask=0077\nTimeoutStartSec=90\nExecStart=/usr/local/lib/remoteagents/server/server-apply.sh _reconcile\n',
        '/etc/systemd/system/' + UNIT + '.timer': '[Unit]\nDescription=Restore confirmed server every 30 seconds\n[Timer]\nOnBootSec=15s\nOnUnitInactiveSec=30s\nAccuracySec=1s\n[Install]\nWantedBy=timers.target\n'}


def refs(value):
    if isinstance(value, dict):
        if 'secret' in value:
            yield value['secret']
        else:
            for child in value.values():
                yield from refs(child)
    elif isinstance(value, list):
        for child in value:
            yield from refs(child)


def portable(engine):
    config = {k: v for k, v in engine.config.items() if k not in ('secrets', 'server')}
    config['server'] = {k: v for k, v in engine.config.get('server', {}).items() if k in ('login', 'address', 'port')}
    optional = set(refs(config.get('agents', {})))
    values = {k: engine.secrets.get(k, '') if k in optional else engine.secret({'secret': k}, k) for k in refs(config)}
    return dict(schema=1, config=config, secrets=values)


def envelope(engine):
    result = portable(engine)
    # Ownership is recorded ONLY when initial TUN is confirmed in a later SSH.
    # Do not silently take ownership of an existing, manually configured sing-box.
    if engine.receipts.get('base-network', {}).get('managed'):
        result['singbox'] = engine.s.path('/etc/sing-box/config.json').read_text()
    result['lan'] = {}
    for item in engine.config.get('lan', []):
        name = engine_module_name(engine, item)
        files = {}
        for filename in ('config.json', 'client.conf'):
            path = engine.s.path('/etc/remoteagents/lan/' + name + '/' + filename)
            if path.is_file():
                files[filename] = path.read_text()
        if len(files) == 2:
            result['lan'][name] = files
    return result


def pin_network(engine):
    """Called under network.lock before clearing pending on an inbound commit.

    Keep the already-confirmed network if later user-component installation fails
    or the caller exits before the final envelope save. Do not accept unconfirmed
    user-component edits in this narrow commit.
    """
    path = engine.s.path(ENVELOPE)
    if not path.exists():
        return
    if path.is_symlink() or path.stat().st_mode & 0o777 != 0o600:
        raise ValueError('unsafe recovery envelope')
    data = engine.s.read(ENVELOPE)
    data['singbox'] = engine.s.path('/etc/sing-box/config.json').read_text()
    for key in ('serverNetwork', 'proxyOut'):
        if key in engine.config:
            data['config'][key] = engine.config[key]
            for name in refs(engine.config[key]):
                data['secrets'][name] = engine.secret({'secret': name}, name)
    engine.s.write(ENVELOPE, json.dumps(data, sort_keys=True, ensure_ascii=False) + '\n')


def engine_module_name(engine, item):
    # Same server-side name validation as the LAN installer; no paths in config.
    if not re.fullmatch('[a-z][a-z0-9]{0,6}', item['name']):
        raise ValueError('invalid LAN name')
    return item['name']


def install(engine, apply):
    s = engine.s
    wanted = units()
    ready = all(s.path(p).is_file() and s.path(p).read_text() == data for p, data in wanted.items())
    enabled = s.run(['systemctl', 'is-enabled', '--quiet', UNIT + '.timer'], check=False).returncode == 0
    live = s.active(UNIT + '.timer')
    private = s.path(ENVELOPE)
    secure = private.is_file() and not private.is_symlink() and private.stat().st_mode & 0o777 == 0o600
    if s.root == Path('/') and secure:
        secure = private.stat().st_uid == 0 and private.stat().st_gid == 0
    if not apply and not engine.public_only:
        desired = portable(engine)
        try:
            stored = s.read(ENVELOPE, {}) if secure else {}
            ready = ready and all(stored.get(k) == desired[k] for k in ('config', 'secrets'))
        except (ValueError, OSError):
            ready = False
    if apply:
        data = envelope(engine)
        parent = s.path(ENVELOPE).parent
        if parent.is_symlink():
            raise ValueError('unsafe recovery directory')
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if s.root == Path('/') and (parent.stat().st_uid != 0 or parent.stat().st_mode & 0o022):
            raise ValueError('unsafe recovery directory ownership')
        os.chmod(parent, 0o700)
        text = json.dumps(data, sort_keys=True, ensure_ascii=False) + '\n'
        if len(text.encode()) > MAX_ENVELOPE:
            raise ValueError('recovery envelope exceeds limit')
        s.write(ENVELOPE, text)
        changed = engine.install_code()
        for path, text in wanted.items():
            changed = s.write(path, text, 0o644) or changed
        if changed:
            s.run(['systemctl', 'daemon-reload'], change=True)
        if not enabled or not live:
            s.run(['systemctl', 'enable', '--now', UNIT + '.timer'], change=True)
        ready = secure = enabled = live = True
    return engine.row('recovery', 'ready' if ready and secure and enabled and live else 'change',
                      'root-only конфиг; сверка каждые 30 с и после загрузки' if ready and secure and enabled and live else 'нужно обновить защищённый конфиг или таймер восстановления')


def restore_lans(app, engine, saved):
    s = engine.s
    for item in engine.config.get('lan', []):
        name = app.lan.name_ok(item['name'])
        files = saved.get(name)
        if not files:
            continue
        directory = '/etc/remoteagents/lan/' + name + '/'
        try:
            current = s.read(directory + 'config.json', {})
        except (ValueError, OSError):
            current = {}
        wanted = json.loads(files['config.json'])
        stable = lambda c: {k: v for k, v in c.items() if k not in ('ready', 'confirmed_at')}
        client = s.path(directory + 'client.conf')
        changed = (stable(current) != stable(wanted) or not client.is_file() or
                   client.read_text() != files['client.conf'])
        unit = 'remoteagents-lan@' + name + '.service'
        if not changed and s.active(unit) and current.get('ready'):
            continue
        # OpenVPN's stop/start hooks take network.lock themselves. Never wait on
        # systemd while holding that lock, otherwise ExecStopPost deadlocks.
        s.run(['systemctl', 'stop', unit], change=True)
        with s.network_lock():
            app.require(not any(s.path(p).exists() for p in PENDING), 'Есть незавершённая сетевая транзакция.')
            for filename, text in files.items():
                app.require(filename in ('config.json', 'client.conf'), 'Неверный снимок ЛВС.')
                s.write(directory + filename, text)
        s.run(['systemctl', 'enable', '--now', unit], change=True)
        deadline = time.monotonic() + 25
        while not s.read(directory + 'config.json', {}).get('ready'):
            app.require(time.monotonic() < deadline, 'Подтверждённая ЛВС не восстановилась.')
            time.sleep(.5)
        engine.lan_test(item)


def reconcile(app, system=None):
    s = system or app.System()
    file = s.path(ENVELOPE)
    app.require(file.is_file() and not file.is_symlink() and file.stat().st_mode & 0o777 == 0o600,
                'Нет защищённого конфига восстановления.')
    if s.root == Path('/'):
        app.require(file.stat().st_uid == 0 and file.stat().st_gid == 0, 'Конфиг восстановления должен принадлежать root.')
    data = app.strict_json(file.read_text(), limit=MAX_ENVELOPE)
    app.require(data.get('schema') == 1, 'Неизвестный формат восстановления.')
    app.validate(data['config'])
    engine = app.Engine(data['config'], data['secrets'], s)
    # Dependencies must exist before jq/nft/sing-box/OpenVPN can inspect or heal.
    # Every manager's rollback and external confirmation keep precedence. The
    # watchdog must never replace an in-flight change or acknowledge its own SSH.
    with s.network_lock():
        if any(s.path(p).exists() for p in PENDING):
            return False
        app.packages.ensure(engine, True)
        if engine.config.get('proxyOut'):
            engine.network_guard()
        if data.get('singbox'):
            desired = data['singbox']
            target = s.path('/etc/sing-box/config.json')
            old = target.read_bytes() if target.exists() else None
            changed = old != desired.encode()
            if changed:
                with s.private_file(desired) as check:
                    s.run(['sing-box', 'check', '-c', check])
                s.write('/etc/sing-box/config.json', desired)
            if changed or not s.active('sing-box') or not engine.egress_check()[0]:
                try:
                    s.run(['systemctl', 'enable', 'sing-box'], change=True)
                    s.run(['systemctl', 'restart', 'sing-box'], change=True)
                    deadline = time.monotonic() + 25
                    while not engine.egress_check()[0]:
                        app.require(time.monotonic() < deadline, 'Подтверждённая сеть не восстановилась.')
                        time.sleep(.5)
                    app.require(engine.inbound_check()[0], 'Защита входящих не восстановилась.')
                except Exception:
                    if changed:
                        if old is None:
                            target.unlink(missing_ok=True)
                        else:
                            s.write('/etc/sing-box/config.json', old)
                        s.run(['systemctl', 'restart', 'sing-box'], check=False, change=True)
                    raise
        elif engine.config.get('proxyOut'):
            app.egress_watch(engine)
    restore_lans(app, engine, data.get('lan', {}))
    # Existing managers validate profiles and preserve their transaction/rollback
    # mechanisms. Newly pending LAN/proxy changes still require external SSH.
    result = engine.run('apply')
    s.write('/var/lib/remoteagents-status/recovery.json', json.dumps(dict(
        ok=result['ok'], checkedAt=int(time.time()), parts=result['parts']), ensure_ascii=False) + '\n', 0o644)
    return result['ok']
