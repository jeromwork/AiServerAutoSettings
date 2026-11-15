#!/usr/bin/env python3
"""Declarative user services. Installers remain repository/vendor implementations.

Credentials cross runuser only over stdin; root never writes into user-controlled
paths. Identity snapshots contain an allowlisted set of files, never project data.
"""
import json
from pathlib import Path
import re

SOURCE = Path(__file__).resolve().parent
ASSETS = ('disk/server-disk.sh', 'disk/stignore.txt', 'codex-windows-bridge.py',
          'codex-bridge-session.py', 'server_node_catalog.py', 'server-codex-v1.sh',
          'server-claude-code.sh', 'server-agent-handoff.py', 'server-desktop-bootstrap.sh', 'close-idle-chats.py')
class Error(Exception):
    pass


KEYS = ('serverComponents', 'agents', 'desktop', 'projectViews', 'sessions', 'ssh')


def assets(source):
    for name in ASSETS:
        packaged = source / 'assets' / name
        yield name, packaged if packaged.exists() else source.parent / name


def section(e, name):
    return e.config.get('telegramGateway', {}) if name == 'telegram' else e.config.get('serverComponents', {}).get(name, {})


def hydrate(e):
    """Omitted identity means keep this managed server's identity, not regenerate."""
    p = e.s.path('/etc/remoteagents/server-apply/recovery.json')
    if not p.is_file() or p.is_symlink() or p.stat().st_mode & 0o777 != 0o600 or (e.s.root == Path('/') and (p.stat().st_uid != 0 or p.stat().st_gid != 0)):
        return
    try:
        saved = e.s.read('/etc/remoteagents/server-apply/recovery.json')
        if saved['config'].get('server', {}).get('login') != e.config.get('server', {}).get('login'):
            return
        for name in ('disk', 'bridge', 'happier', 'telegram'):
            item = section(e, name)
            old = saved['config'].get('telegramGateway', {}) if name == 'telegram' else saved['config'].get('serverComponents', {}).get(name, {})
            if item.get('enabled') and not item.get('identity') and old.get('identity'):
                item['identity'] = old['identity']
                key = old['identity']['secret']
                e.secrets.setdefault(key, saved['secrets'][key])
    except (ValueError, KeyError, TypeError):
        return


def io(e, kind, action='read', files=None):
    cmd = e.user_cmd('python3', '-I', e.s.path('/usr/local/lib/remoteagents/server/component_files.py'))
    return json.loads(e.s.run(cmd, input=json.dumps(dict(kind=kind, action=action, files=files)), change=action not in ('read', 'health')).stdout)


def identity(e, name, files=None):
    item = section(e, name)
    if files is None:
        if not item.get('identity'):
            return None
        # Parse/validate even in plan, without touching any user files.
        data = json.loads(e.secret(item['identity'], 'server-' + name + '-identity'))
        data = e.module_files.validate(name, data)
        e.secrets[item['identity']['secret']] = json.dumps(data, sort_keys=True)
        return data
    ref = item.setdefault('identity', {'secret': 'server-' + name + '-identity'})
    e.secrets[ref['secret']] = json.dumps(e.module_files.validate(name, files), sort_keys=True)


def user_ready(e):
    user, uid, home = e.worker()
    if not e.s.path('/var/lib/systemd/linger/' + user).exists():
        e.s.run(['loginctl', 'enable-linger', user], change=True)
    if not e.s.active('user@' + str(uid) + '.service'):
        e.s.run(['systemctl', 'start', 'user@' + str(uid) + '.service'], change=True)


def unit(e, name, text, apply):
    _, _, home = e.worker()
    path = '.config/systemd/user/' + name
    current = e.s.path(home / path)
    same = current.is_file() and not current.is_symlink() and current.read_text() == text
    live = e.s.run(e.user_cmd('systemctl', '--user', 'is-active', '--quiet', name), check=False).returncode == 0
    enabled = e.s.run(e.user_cmd('systemctl', '--user', 'is-enabled', '--quiet', name), check=False).returncode == 0
    if apply:
        if not same:
            io(e, 'bridge', 'assets', {path: text})
            e.s.run(e.user_cmd('systemctl', '--user', 'daemon-reload'), change=True)
        if not enabled:
            e.s.run(e.user_cmd('systemctl', '--user', 'enable', name), change=True)
        if not same or not live:
            e.s.run(e.user_cmd('systemctl', '--user', 'restart', name), change=True)
        return e.s.run(e.user_cmd('systemctl', '--user', 'is-active', '--quiet', name), check=False).returncode == 0
    return same and enabled and live


def disable(e, names, apply):
    changed = False
    for name in names:
        live = e.s.run(e.user_cmd('systemctl', '--user', 'is-active', '--quiet', name), check=False).returncode == 0
        enabled = e.s.run(e.user_cmd('systemctl', '--user', 'is-enabled', '--quiet', name), check=False).returncode == 0
        changed |= live or enabled
        if apply and (live or enabled):
            e.s.run(e.user_cmd('systemctl', '--user', 'disable', '--now', name), change=True)
    return e.row(names[0], 'change' if changed and not apply else 'ready', 'будет выключен' if changed and not apply else 'выключен')


def disk(e, apply):
    item = section(e, 'disk')
    if not item.get('enabled'):
        return disable(e, ['remote-disk-folders.timer', 'remoteagents-syncthing.service'], apply)
    saved = identity(e, 'disk')
    _, _, home = e.worker()
    base = home / '.local/share/remote-disk'
    source = dict(assets(e.s.source))
    wanted = {'.local/share/remote-disk/' + Path(n).name: source[n].read_text() for n in ('disk/server-disk.sh', 'disk/stignore.txt')}
    scripts_ok = all(e.s.path(home / n).is_file() and e.s.path(home / n).read_text() == t for n, t in wanted.items())
    service = ('[Unit]\nDescription=RemoteDisk Syncthing\n[Service]\nExecStart=%h/.local/share/remote-disk/bin/syncthing serve --home=%h/.local/share/remote-disk --no-browser --no-restart --no-upgrade\nRestart=always\nRestartSec=2\nUMask=0077\n[Install]\nWantedBy=default.target\n')
    # The existing bootstrap also manages folder acceptance and the fast timer.
    ok = scripts_ok and e.s.path(base / 'bin/syncthing').is_file()
    current = {}
    if ok:
        try:
            current = io(e, 'disk')
            e.module_files.validate('disk', current)
            if saved:
                ok = all(current.get(n) == saved[n] for n in e.module_files.FIXED['disk'][1:3])
        except Exception:
            ok = False
    ok = ok and unit(e, 'remoteagents-syncthing.service', service, False)
    timer = e.s.path(home / '.config/systemd/user/remote-disk-folders.timer')
    drop = e.s.path(home / '.config/systemd/user/remote-disk-folders.timer.d/interval.conf')
    wanted_interval = '[Timer]\nOnUnitInactiveSec=\nOnUnitInactiveSec=' + str(item.get('discoveryIntervalSec', 2)) + 's\n'
    ok = ok and timer.is_file() and drop.is_file() and drop.read_text() == wanted_interval
    if ok:
        try:
            ok = io(e, 'disk', 'health').get('ok', False)
        except Exception:
            ok = False
    ok = ok and e.s.run(e.user_cmd('systemctl', '--user', 'is-active', '--quiet', 'remote-disk-folders.timer'), check=False).returncode == 0
    if not apply:
        return e.row('disk', 'ready' if ok else 'change', 'Syncthing и таймер проверены' if ok else 'будут восстановлены Syncthing, идентичность и таймер')
    if not ok:
        user_ready(e)
        e.install_code()
        # Stop the fast bootstrap before restoring malformed config/certificates.
        e.s.run(e.user_cmd('systemctl', '--user', 'stop', 'remote-disk-folders.timer', 'remoteagents-syncthing.service'), check=False, change=True)
        # A legacy bootstrap may have started Syncthing outside systemd. Terminate
        # only this user's exact Syncthing --home, never an unrelated process.
        e.s.run(e.user_cmd('python3', '-I', '-c', 'import os,signal; from pathlib import Path; h=str(Path.home()/".local/share/remote-disk").encode(); [(os.kill(int(p.name),signal.SIGTERM)) for p in Path("/proc").iterdir() if p.name.isdigit() and p.stat().st_uid==os.getuid() and p.joinpath("cmdline").exists() and b"syncthing\\x00serve\\x00--home\\x00"+h+b"\\x00" in p.joinpath("cmdline").read_bytes()]'), check=False)
        if saved:
            io(e, 'disk', 'identity', saved)
        io(e, 'disk', 'assets', wanted)
        e.s.run(e.user_cmd('bash', base / 'server-disk.sh', 'bootstrap'), change=True, timeout=90)
        # Stop the legacy detached process before handing it to systemd.
        e.s.run(e.user_cmd(str(base / 'bin/syncthing'), 'cli', '--home', base, 'operations', 'shutdown'), check=False)
        import time
        time.sleep(.5)
        if not unit(e, 'remoteagents-syncthing.service', service, True):
            raise ValueError('Syncthing did not start')
        e.s.run(e.user_cmd('bash', base / 'server-disk.sh', 'bootstrap'), timeout=60)
    files = io(e, 'disk')
    identity(e, 'disk', files)
    # Bootstrap's legacy 2s timer is overridden declaratively, and checked here.
    text = '[Timer]\nOnUnitInactiveSec=\nOnUnitInactiveSec=' + str(item.get('discoveryIntervalSec', 2)) + 's\n'
    drop = '.config/systemd/user/remote-disk-folders.timer.d/interval.conf'
    if not e.s.path(home / drop).is_file() or e.s.path(home / drop).read_text() != text:
        io(e, 'disk', 'assets', {drop: text})
        e.s.run(e.user_cmd('systemctl', '--user', 'daemon-reload'), change=True)
        e.s.run(e.user_cmd('systemctl', '--user', 'restart', 'remote-disk-folders.timer'), change=True)
    return e.row('disk', 'ready', 'Syncthing, идентичность и таймер восстановлены')


def bridge(e, apply):
    item = section(e, 'bridge')
    if not item.get('enabled'):
        return e.row('bridge', 'ready', 'мост не выбран')
    saved = identity(e, 'bridge')
    _, _, home = e.worker()
    wanted = {'.local/share/codex-remote/' + n: p.read_text() for n, p in assets(e.s.source) if n in ('codex-windows-bridge.py', 'codex-bridge-session.py', 'server_node_catalog.py', 'server-agent-handoff.py')}
    ok = all(e.s.path(home / n).is_file() and e.s.path(home / n).read_text() == t for n, t in wanted.items())
    if saved:
        ok = ok and io(e, 'bridge') == saved
    if apply:
        e.install_code()
        if not ok:
            if saved:
                # Merge keys issued since the snapshot; never lock out this apply.
                current = io(e, 'bridge')
                key = '.ssh/authorized_keys'
                if key in current:
                    saved[key] = '\n'.join(dict.fromkeys((saved.get(key, '') + '\n' + current[key]).splitlines())) + '\n'
                io(e, 'bridge', 'identity', saved)
            io(e, 'bridge', 'assets', wanted)
        # MCP is a stdio process launched by agents, not a persistent daemon.
        for cli in ('codex', 'claude'):
            binary = str(home / '.local/bin/claude') if cli == 'claude' else 'codex'
            listed = e.s.run(e.user_cmd(binary, 'mcp', 'list'), check=False)
            if listed.returncode == 0 and 'windows-control' not in listed.stdout:
                args = ['mcp', 'add', 'windows-control', '--', '/usr/bin/python3', str(home / '.local/share/codex-remote/codex-windows-bridge.py'), '--catalog', str(home / '.local/share/remote-agents-nodes')]
                if cli == 'claude':
                    args = ['mcp', 'add', '--transport', 'stdio', '--scope', 'user', *args[2:]]
                e.s.run(e.user_cmd(binary, *args), change=True)
        identity(e, 'bridge', io(e, 'bridge'))
        ok = True
    return e.row('bridge', 'ready' if ok else 'change', 'MCP-мост и ключи сохранены' if ok else 'будут установлены MCP-мост и его ключи')


def telegram_restore(e, apply):
    if not section(e, 'telegram').get('enabled'):
        return False
    saved = identity(e, 'telegram')
    if not saved:
        return False
    # Restore before invoking the existing installer: it must not generate new TLS.
    if apply:
        e.install_code()
    try:
        current = io(e, 'telegram')
    except Exception:
        current = {}
    # Client keys may be added/revoked by the gateway CLI between reconciles.
    # Accept valid live key rotations; repair malformed/missing key stores.
    keys = '.local/opt/tg-gateway/state/keys.json'
    try:
        live_keys = json.loads(current.get(keys, 'null'))
        if live_keys.get('version') == 1 and isinstance(live_keys.get('keys'), dict):
            saved[keys] = current[keys]
    except (ValueError, AttributeError):
        pass
    different = current != saved
    if different and apply:
        user_ready(e)
        e.s.run(e.user_cmd('systemctl', '--user', 'stop', 'tg-gateway.service'), check=False, change=True)
        io(e, 'telegram', 'identity', saved)
    return different


def telegram_capture(e):
    e.install_code()
    files = io(e, 'telegram')
    # An empty keys.json is still an explicit portable identity; the gateway
    # otherwise creates it lazily on the first client-key operation.
    key = '.local/opt/tg-gateway/state/keys.json'
    if key not in files:
        files[key] = '{"version":1,"keys":{}}\n'
        io(e, 'telegram', 'identity', files)
    identity(e, 'telegram', files)


def install_vendor(e, kind, expected=''):
    _, _, home = e.worker()
    binary = home / ('.local/bin/claude' if kind == 'claude' else '.local/bin/happier')
    result = e.s.run(e.user_cmd(str(binary), '--version'), check=False)
    if result.returncode == 0 and (not expected or expected in result.stdout.split()):
        return True
    user_ready(e)
    # Reuse the existing official vendor installers, always as the worker.
    script = '''set -euo pipefail
umask 077
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
curl -q --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 "$1" -o "$stage/install.sh"
url="$1"; shift
bash "$stage/install.sh" "$@"
'''
    url = 'https://claude.ai/install.sh' if kind == 'claude' else 'https://happier.dev/install'
    args = [expected or 'stable'] if kind == 'claude' else ['--yes', *(['--version', expected] if expected else [])]
    e.s.run(e.user_cmd('bash', '-c', script, 'vendor-install', url, *args), change=True, timeout=900)
    result = e.s.run(e.user_cmd(str(binary), '--version'), check=False)
    if result.returncode or expected and expected not in result.stdout.split():
        raise Error('Версия установленного CLI не совпадает с конфигом; установка не подтверждена')
    return True


def agents(e, kind, apply):
    item = e.config['agents'][kind]
    if not item.get('enabled'):
        return e.row('agents:' + kind, 'ready', 'агент не выбран')
    user, uid, home = e.worker()
    expected = item.get('version', '0.166.0' if kind == 'codex' else '')
    binary = 'codex' if kind == 'codex' else str(home / '.local/bin/claude')
    check = e.s.run(e.user_cmd(binary, '--version'), check=False)
    installed = check.returncode == 0 and (not expected or expected in check.stdout.split())
    auth = None
    if item.get('auth'):
        auth = e.secrets.get(item['auth']['secret'])
    token = e.secrets.get(item.get('token', {}).get('secret'))
    if apply:
        # Only our bootstrap-created canonical user may receive legacy installer
        # privileges. A matching username alone is not authorization to adopt it.
        marker = e.s.path('/var/lib/remote-agents/managed-user-v1')
        if kind == 'codex':
            if user != 'remoteagents' or not marker.is_file() or marker.is_symlink() or marker.stat().st_mode & 0o022 or e.s.root == Path('/') and marker.stat().st_uid != 0 or marker.read_text().strip() != 'remoteagents:/home/remoteagents:v1':
                return e.row('agents:codex', 'blocked', 'Codex требует созданного bootstrap managed-user remoteagents')
            if not installed:
                e.install_code()
                e.s.run(['bash', e.s.path('/usr/local/lib/remoteagents/server/assets/server-codex-v1.sh')], change=True, timeout=900)
        elif not installed:
            install_vendor(e, kind, expected)
        if auth:
            # An auth secret is the vendor's complete JSON, not a made-up token.
            if not isinstance(json.loads(auth), dict):
                raise ValueError('Invalid agent auth JSON')
            name = e.module_files.FIXED[kind][0]
            current = io(e, kind)
            if current.get(name) != auth:
                io(e, kind, 'identity', {name: auth})
        if kind == 'claude' and token:
            if not re.fullmatch(r'[A-Za-z0-9._~+/-]+={0,2}', token):
                raise ValueError('Invalid Claude token')
            # EnvironmentFile is read by systemd, never a shell. The terminal
            # wrapper reads the same root-supplied data without eval/source.
            escaped = token.replace('\\', '\\\\').replace('"', '\\"')
            envfile = 'CLAUDE_CODE_OAUTH_TOKEN="' + escaped + '"\n'
            wrapper = '#!/usr/bin/python3\n# RemoteAgents managed Claude token wrapper\nimport json,os\nfrom pathlib import Path\np=Path.home()/".config/remoteagents/claude.env"\nif p.is_file(): os.environ["CLAUDE_CODE_OAUTH_TOKEN"]=json.loads(p.read_text().split("=",1)[1])\nos.execv(str(Path.home()/".local/bin/claude.vendor"),["claude",*__import__("sys").argv[1:]])\n'
            # Keep the vendor entry beside the wrapper; no secret is embedded in
            # executable code. Native CLI and Happier now read the same token.
            prep = 'import os; from pathlib import Path; p=Path.home()/".local/bin/claude"; marker=b"# RemoteAgents managed Claude token wrapper"; data=p.read_bytes() if p.exists() else b""; os.replace(p,p.with_name("claude.vendor")) if data and marker not in data else None'
            e.s.run(e.user_cmd('python3', '-I', '-c', prep))
            wanted = {'.config/remoteagents/claude.env': envfile, '.local/bin/claude': wrapper}
            if any(not e.s.path(home / n).is_file() or e.s.path(home / n).read_text() != v for n, v in wanted.items()):
                io(e, kind, 'assets', wanted)
        installed = True
    if not installed:
        return e.row('agents:' + kind, 'change', 'будет установлен CLI выбранной версии/канала')
    if not apply and (auth or token):
        good = True
        if auth:
            current = io(e, kind) if e.code_current() else {}
            good = current.get(e.module_files.FIXED[kind][0]) == auth
        if token:
            envfile = e.s.path(home / '.config/remoteagents/claude.env')
            good = good and envfile.is_file() and ('CLAUDE_CODE_OAUTH_TOKEN=' + json.dumps(token) + '\n') == envfile.read_text()
        if not good:
            return e.row('agents:' + kind, 'change', 'CLI установлен; будет восстановлена авторизация из секрета')

    if not auth and not token:
        # Recognize an already-authorized managed account without exposing it.
        if kind == 'codex':
            logged = e.s.run(e.user_cmd('codex', 'login', 'status'), check=False).returncode == 0
        else:
            logged = bool(io(e, kind).get(e.module_files.FIXED[kind][0])) if e.code_current() else False
        if not logged:
            return e.row('agents:' + kind, 'waiting', 'CLI установлен; нужен вход: ' + ('codex login --device-auth' if kind == 'codex' else 'claude auth login'))
        if apply:
            current = io(e, kind)
            if current.get(e.module_files.FIXED[kind][0]):
                ref = item.setdefault('auth', {'secret': 'agent-' + kind + '-auth'})
                e.secrets[ref['secret']] = current[e.module_files.FIXED[kind][0]]
    return e.row('agents:' + kind, 'ready', 'CLI установлен; авторизация доступна')


def happier(e, apply):
    item = section(e, 'happier')
    if not item.get('enabled'):
        return disable(e, ['remoteagents-happier.service'], apply)
    saved = identity(e, 'happier')
    _, _, home = e.worker()
    binary = home / '.local/bin/happier'
    version = e.s.run(e.user_cmd(str(binary), '--version'), check=False)
    installed = version.returncode == 0 and (not item.get('version') or item['version'] in version.stdout.split())
    service = ('[Unit]\nDescription=RemoteAgents Happier daemon\nAfter=network-online.target\n[Service]\nType=simple\n'
               'Environment="PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin"\n'
               'EnvironmentFile=-%h/.config/remoteagents/claude.env\n'
               'ExecStart=%h/.local/bin/happier daemon start-sync\nRestart=on-failure\nRestartSec=5\nUMask=0077\n[Install]\nWantedBy=default.target\n')
    if apply:
        if not installed:
            install_vendor(e, 'happier', item.get('version', ''))
        user_ready(e)
        e.install_code()
        if saved and io(e, 'happier') != saved:
            io(e, 'happier', 'identity', saved)
        # Adopt only the explicitly selected native/default mode; stop that
        # legacy daemon to prevent two daemons for the same machine identity.
        before = len(e.rows)
        disable(e, ['happier-daemon.default.service'], True)
        del e.rows[before:]
        files = io(e, 'happier')
        if files:
            identity(e, 'happier', files)
        installed = True
    if not installed:
        return e.row('happier', 'change', 'будет установлен Happier stable')
    credentials = saved or (files if apply else {})
    if not any(n.endswith('access.key') for n in credentials):
        return e.row('happier', 'waiting', 'Happier установлен; нужен вход в аккаунт Happier')
    ok = unit(e, 'remoteagents-happier.service', service, apply)
    return e.row('happier', 'ready' if ok else 'change', 'Happier и авторизация восстановлены' if ok else 'будет восстановлена служба Happier')


def extras(e, apply):
    desktop = e.config.get('desktop', {})
    if desktop.get('enabled'):
        if desktop.get('backend', 'desktop') != 'desktop':
            e.row('desktop', 'blocked', 'Для native desktop нет установщика в репозитории; нужна ручная установка')
        else:
            checker = e.s.path('/usr/local/lib/remoteagents-desktop/check.py')
            ok = checker.is_file() and e.s.run(['python3', '-I', checker], check=False).returncode == 0
            if not ok and apply:
                e.install_code()
                e.s.run(['bash', e.s.path('/usr/local/lib/remoteagents/server/assets/server-desktop-bootstrap.sh'), e.worker()[0]], change=True, timeout=900)
                ok = e.s.run(['python3', '-I', checker], check=False).returncode == 0
            e.row('desktop', 'ready' if ok else 'change', 'desktop проверен' if ok else 'будет установлен desktop из репозитория')
    if e.config.get('projectViews', {}).get('enabled'):
        e.row('projectViews', 'blocked', 'project views: установщик есть только на 109, исходника в репозитории нет; нужен перенос кода')
    sessions = e.config.get('sessions', {})
    if 'cleanupEnabled' in sessions:
        if not sessions['cleanupEnabled']:
            disable(e, ['remoteagents-close-idle.timer'], apply)
        else:
            service = ('[Service]\nType=oneshot\nExecStart=/usr/bin/python3 /usr/local/lib/remoteagents/server/assets/close-idle-chats.py --hours=' + str(sessions.get('idleHours', 2)) + '\n')
            timer = ('[Timer]\nOnBootSec=1m\nOnUnitInactiveSec=' + str(sessions.get('intervalMinutes', 15)) + 'm\n[Install]\nWantedBy=timers.target\n')
            if apply:
                e.install_code(); user_ready(e)
            # An inactive oneshot service is expected; only the timer is active.
            _, _, home = e.worker()
            path = '.config/systemd/user/remoteagents-close-idle.service'
            same = e.s.path(home / path).is_file() and e.s.path(home / path).read_text() == service
            if not same and apply:
                io(e, 'bridge', 'assets', {path: service})
                e.s.run(e.user_cmd('systemctl', '--user', 'daemon-reload'), change=True)
                same = True
            ok = unit(e, 'remoteagents-close-idle.timer', timer, apply) and same
            e.row('sessions', 'ready' if ok else 'change', 'таймер закрытия чатов проверен' if ok else 'будет установлен таймер закрытия чатов')
