#!/usr/bin/env python3
"""Bounded private user-file IO. Always executed as the worker, never as root.

Own format is a fixed allowlist, not a general restore/archive interpreter.
"""
import json
import os
from pathlib import Path
import re
import sys
import tempfile

FIXED = {
    'disk': ('.local/share/remote-disk/config.xml', '.local/share/remote-disk/cert.pem',
             '.local/share/remote-disk/key.pem', '.local/share/remote-disk/ports.json'),
    'telegram': ('.local/opt/tg-gateway/tls/cert.pem', '.local/opt/tg-gateway/tls/key.pem',
                 '.local/opt/tg-gateway/state/keys.json', '.local/opt/tg-gateway/state/settings.json'),
    'bridge': ('.ssh/authorized_keys', '.ssh/remoteagents-revoked.json', '.ssh/id_ed25519', '.ssh/id_ed25519.pub', '.codex/config.toml', '.claude.json',
               '.local/share/remote-agent-handoff/instructions.md'),
    'happier': ('.happier/settings.json', '.happier/access.key'),
    'codex': ('.codex/auth.json',),
    'claude': ('.claude/.credentials.json',),
}


def allowed(kind, name):
    if name in FIXED[kind]:
        return True
    if kind == 'bridge':
        return bool(re.fullmatch(r'\.local/share/remote-agents-nodes/[a-z0-9][a-z0-9_-]{0,63}/[a-z0-9][a-z0-9_-]{0,63}\.json', name))
    if kind == 'happier':
        return bool(re.fullmatch(r'\.happier/servers/[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}/(?:access.key|settings.json)', name))
    return False


def path(name):
    p = Path.home() / name
    if any(x.is_symlink() for x in (p, *p.parents)):
        raise ValueError('symlink')
    return p


def telegram_keys(text):
    # Reuse the gateway CLI's validator; no second credential-store dialect.
    import importlib.util
    spec = importlib.util.spec_from_file_location('component_tg_keys', Path(__file__).parent / 'tg-gateway/tg_gateway_keys.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module.validate_keys(json.loads(text))


def validate(kind, files):
    if not isinstance(files, dict) or len(files) > 256 or any(not allowed(kind, n) or not isinstance(v, str) for n, v in files.items()):
        raise ValueError('invalid component identity')
    if kind == 'disk':
        import xml.etree.ElementTree as ET
        if not set(FIXED[kind]) <= files.keys() or ET.fromstring(files[FIXED[kind][0]]).tag != 'configuration':
            raise ValueError('incomplete Syncthing identity')
        ports = json.loads(files[FIXED[kind][3]])
        if any(type(ports.get(n)) is not int or not 1 <= ports[n] <= 65535 for n in ('gui', 'listen')):
            raise ValueError('invalid disk ports')
    if kind == 'telegram':
        keys = telegram_keys(files.get(FIXED[kind][2], 'null'))
        if not set(FIXED[kind]) <= files.keys() or not isinstance(keys, dict) or keys.get('version') != 1 or not isinstance(keys.get('keys'), dict):
            raise ValueError('incomplete Telegram identity')
        json.loads(files[FIXED[kind][3]])
    return files


def restore_bridge_keys(files):
    import importlib.util
    import getpass
    spec = importlib.util.spec_from_file_location('bridge_key_io', Path(__file__).with_name('remoteagents_config.py'))
    rc = importlib.util.module_from_spec(spec); spec.loader.exec_module(rc)
    ak = path('.ssh/authorized_keys')
    revoked = path('.ssh/remoteagents-revoked.json')
    c = {'workerUser': getpass.getuser(), 'workerAuthorizedKeys': str(ak)}
    def ids(text):
        value = json.loads(text or '[]')
        if not isinstance(value, list) or any(not isinstance(i, str) or not re.fullmatch('[a-f0-9]{16}', i) for i in value):
            raise ValueError('invalid explicit revocations')
        return set(value)
    if '.ssh/remoteagents-revoked.json' in files or revoked.exists():
        restored = ids(files.pop('.ssh/remoteagents-revoked.json', '[]'))
        rc.replace_worker(c, revoked, lambda old: json.dumps(sorted(ids(old) | restored)) + '\n')
    if '.ssh/authorized_keys' in files:
        restored = files.pop('.ssh/authorized_keys')
        def merge(old):
            forbidden = ids(rc.read_worker(c, revoked))
            lines = list(dict.fromkeys((restored + '\n' + old).splitlines()))
            def keep(line):
                parsed = rc.parse_key_line(line)
                label = rc.config_label(parsed[2]) if parsed else None
                return not label or label[0] not in forbidden
            return '\n'.join(line for line in lines if line and keep(line)) + '\n'
        rc.replace_worker(c, ak, merge)


def main():
    request = json.loads(sys.stdin.read(4 * 1024 * 1024 + 1))
    kind, action = request['kind'], request['action']
    if action == 'health':
        import urllib.request
        import xml.etree.ElementTree as ET
        base = Path.home() / '.local/share/remote-disk'
        ports = json.loads(path('.local/share/remote-disk/ports.json').read_text())
        key = ET.fromstring(path('.local/share/remote-disk/config.xml').read_text()).findtext('gui/apikey')
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        req = urllib.request.Request('http://127.0.0.1:' + str(ports['gui']) + '/rest/system/status', headers={'X-API-Key': key})
        with opener.open(req, timeout=3) as response:
            print(json.dumps({'ok': bool(json.load(response).get('myID'))}))
    elif action == 'read':
        names = list(FIXED[kind])
        pattern = {'bridge': '.local/share/remote-agents-nodes/*/*.json', 'happier': '.happier/servers/*/*.json'}.get(kind)
        if pattern:
            names += [str(p.relative_to(Path.home())) for p in Path.home().glob(pattern)]
        if kind == 'happier':
            names += [str(p.relative_to(Path.home())) for p in Path.home().glob('.happier/servers/*/access.key')]
        files = {n: path(n).read_text() for n in names if allowed(kind, n) and path(n).is_file()}
        if len(json.dumps(files).encode()) > 3 * 1024 * 1024:
            raise ValueError('identity too large')
        print(json.dumps(files))
    else:
        files = validate(kind, request['files']) if action == 'identity' else request['files']
        if kind == 'bridge' and action == 'identity':
            restore_bridge_keys(files)
        # Asset writes have a separate exact allowlist passed by trusted code.
        assets = {'.local/share/remote-disk/server-disk.sh', '.local/share/remote-disk/stignore.txt',
                  '.local/share/codex-remote/codex-windows-bridge.py', '.local/share/codex-remote/codex-bridge-session.py',
                  '.local/share/codex-remote/server_node_catalog.py', '.local/share/codex-remote/server-agent-handoff.py', '.local/bin/claude',
                  '.config/remoteagents/claude.env', '.config/remoteagents/happier-web.json'}
        for name, value in files.items():
            if action != 'identity' and name not in assets and not re.fullmatch(r'\.config/systemd/user/(?:remoteagents-[a-z0-9.-]+|remote-disk-folders\.(?:timer|service)|tg-gateway\.service)(?:\.d/[a-z0-9.-]+\.conf)?', name):
                raise ValueError('invalid asset path')
            p = path(name)
            p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd, tmp = tempfile.mkstemp(dir=p.parent)
            try:
                with os.fdopen(fd, 'w') as stream:
                    os.fchmod(stream.fileno(), 0o700 if name == '.local/bin/claude' else 0o600)
                    stream.write(value)
                os.replace(tmp, p)
            finally:
                Path(tmp).unlink(missing_ok=True)
        print('{}')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('Private component IO failed; values hidden')
