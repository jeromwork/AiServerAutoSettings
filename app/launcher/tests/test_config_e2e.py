#!/usr/bin/env python3
"""Сквозной тест CONFIG на loopback-стенде (без root, временные HOME, настоящие OpenSSH/sshd/sing-box):

`remoteagents config export` (B, мастер-пароль) → текст конфига → ConfigBundle.Parse/Unlock/Store/Materialize (A)
→ оркестратор ConfigEngine (D) запускает настоящие действия Wizard.ps1 Server, Connection, Vpn (C); Bridge/Account/Disk —
стендовые (нужны Windows/Happier/Syncthing) → живой SSH-вход ключом из конфига → ConfigSync по снимку сервера (B→C)
→ `config revoke` → новый вход отвергнут.

Не трогает ~/.ssh, authorized_keys рабочего пользователя, службы, мост и Windows.
"""
import contextlib
import json
import os
from pathlib import Path
import pwd
import secrets
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid

REPO = Path(__file__).resolve().parents[3]
PWSH = Path(os.environ.get('PWSH') or Path.home() / '.cache/pwsh-test/pwsh')
DOTNET = Path(os.environ.get('DOTNET') or Path.home() / '.dotnet/dotnet')
USER = pwd.getpwuid(os.getuid()).pw_name
MASTER = 'Мастер-пароль стенда 1'
HARNESS = REPO / 'app/launcher/tests/bin/Release/config-e2e/net10.0/PortableTests.dll'


def run(cmd, check=True, **kw):
    kw.setdefault('stdin', subprocess.DEVNULL) if 'input' not in kw else None
    p = subprocess.run([str(x) for x in cmd], capture_output=True, timeout=kw.pop('timeout', 120), **kw)
    if check and p.returncode != 0:
        raise AssertionError(' '.join(map(str, cmd[:4])) + ' → ' + str(p.returncode) + '\n' + p.stdout.decode(errors='replace')[-3000:] + p.stderr.decode(errors='replace')[-3000:])
    return p


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def keygen(path):
    run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', path])
    return ' '.join(Path(str(path) + '.pub').read_text().split()[:2])


def write_sshd_conf(d, port, authorized, server_home, bindir):
    (d / 'sshd.conf').write_text(f'''ListenAddress 127.0.0.1
Port {port}
HostKey {d / 'host'}
PidFile {d / 'sshd.pid'}
AuthorizedKeysFile {authorized}
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers {USER}
AllowTcpForwarding yes
PermitTTY no
SetEnv REMOTE_DISK_CHANNEL_SOURCE={server_home}/no-channel HOME={server_home} PATH={bindir}:/usr/bin:/bin
LogLevel VERBOSE
''')


def wait_port(port, proc, log, host='127.0.0.1'):
    for _ in range(100):
        try:
            with socket.create_connection((host, port), .1):
                return
        except OSError:
            assert proc.poll() is None, Path(log).read_text()
            time.sleep(.03)
    raise AssertionError('port %s:%s did not open' % (host, port))


def main():
    started = time.monotonic()
    os.umask(0o022)  # sshd StrictModes and `remoteagents config` refuse group/other-writable directories
    harness = REPO / 'app/launcher/tests/bin/Release/config-e2e/net10.0/PortableTests.dll'
    run([DOTNET, 'build', REPO / 'app/launcher/tests/PortableTests.csproj', '-c', 'Release', '-p:ConfigE2E=true', '--nologo', '-v:q'], timeout=300)
    with tempfile.TemporaryDirectory(prefix='ra-config-e2e-', delete=not os.environ.get('RA_E2E_KEEP')) as tmp:
        d = Path(tmp)
        server_home = d / 'server'
        (server_home / '.ssh').mkdir(parents=True, mode=0o700)
        server_home.chmod(0o755)
        bindir = server_home / '.local/bin'
        bindir.mkdir(parents=True)
        (bindir / 'systemctl').write_text('#!/bin/sh\nexit 0\n')
        (bindir / 'systemctl').chmod(0o700)
        conf_dir = server_home / '.config/remoteagents'
        conf_dir.mkdir(parents=True, mode=0o700)
        catalog = conf_dir / 'transport-catalog.json'
        catalog.write_text(json.dumps(dict(schema=1, entries=[], hops=[], relays=[], cdn=[])))
        host_pub = keygen(d / 'host')
        port = free_port()
        authorized = server_home / '.ssh/authorized_keys'
        write_sshd_conf(d, port, authorized, server_home, bindir)
        # B: issuing settings (normally /etc/remoteagents/config-export.json), all inside the stand.
        export_cfg = d / 'config-export.json'
        settings = dict(schema=1, version=1, serverAddress='127.0.0.1', serverPort=port, workerUser=USER, hostKeys=[host_pub],
                        workerAuthorizedKeys=str(authorized), stateDir=str(d / 'issued'), syncFile=str(conf_dir / 'config-sync.json'),
                        nodeCatalog=str(server_home / '.local/share/remote-agents-nodes'), catalogFile=str(catalog),
                        authLog=[str(d / 'sshd.log')], routes=[{'kind': 'direct'}])

        def write_settings():
            export_cfg.write_text(json.dumps(settings, ensure_ascii=False))
            export_cfg.chmod(0o600)
        write_settings()

        def b(*args, **kw):
            return run([sys.executable, '-I', REPO / 'server/remoteagents_config.py', '--config', export_cfg, *args], **kw)

        log = (d / 'sshd.log').open('w')
        sshd = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(d / 'sshd.conf')], stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        local = d / 'local'
        root = local / 'RemoteAgents'
        root.mkdir(parents=True)
        env = dict(os.environ, LOCALAPPDATA=str(local), REMOTEAGENTS_CONTROL_IDLE_SECONDS='30')
        try:
            wait_port(port, sshd, d / 'sshd.log')

            # 1. Server (B): full config for one more computer, closed by a master password.
            issued = b('export', '--name', 'Ноутбук сына', '--folders', 'Проект', '--master-password-stdin',
                       input=(MASTER + '\r\n').encode()).stdout.decode()
            secrets = json.loads(issued)['secrets']
            assert MASTER not in issued and secrets['protected'] == 'master-password' and secrets['server-key'].startswith('enc1:'), 'enc1 config expected'
            (d / 'issued.json').write_text(issued)
            assert 'ra-config:' in authorized.read_text()

            # Stand-only transport knobs (unprivileged ports, Linux sing-box); everything else comes from the config.
            (root / 'config.json').write_text(json.dumps(dict(schema=1, version=1, components={}, transport=dict(
                singBoxPath=shutil.which('sing-box'), bindPhysical=False, metered='false', probeTimeoutSec=8, stallSeconds=3,
                sshPort=free_port(), syncPort=free_port(), apiPort=free_port()))))

            # 2. Paste (A): Parse (CRLF) / Unlock / Store / Materialize — the program's own code.
            applied = json.loads(run([DOTNET, harness, '--apply', root, d / 'issued.json'], env=dict(env, RA_E2E_MASTER=MASTER)).stdout)
            assert applied['wrongMasterRefused'] and applied['missing'] == [] and applied['keyMaterialized'], applied
            assert applied['aiHasNoKey'] and applied['fullExportRoundtrip'] and applied['deviceName'] == 'Ноутбук сына', applied
            vault = (root / 'secrets/vault.json').read_text()
            assert MASTER not in vault and MASTER not in (root / 'config.json').read_text()

            # 3. Apply (D orchestrator + C actions): Server, then Connection/Bridge/Account/Disk/Vpn at the same time.
            p = run([DOTNET, harness, '--run', root, REPO, PWSH], env=env, check=False, timeout=400)
            if p.returncode != 0:
                raise AssertionError('apply failed\n' + p.stdout.decode(errors='replace') + p.stderr.decode(errors='replace')[-6000:])
            result = json.loads(p.stdout.decode().strip().splitlines()[-1])
            sections = result['sections']
            assert result['plan'][:2] == ['server', 'connection'] and 'bootstrap' not in result['plan'], result['plan']
            assert all(s['ok'] for s in sections.values()), sections
            assert result['parallelOverlapMs'] > 0, 'independent sections did not overlap'
            config = json.loads((root / 'config.json').read_text(encoding='utf-8-sig'))
            profile = json.loads(Path(config['transport']['profilePath']).read_text(encoding='utf-8-sig'))
            manifest = json.loads((root / 'secrets/materialized.json').read_text())
            assert profile['keyPath'] == manifest['serverKeyFile'], 'the issued key, not another one, is used'
            assert not list((root / 'ssh-profiles').rglob('id_ed25519')), 'no extra device key was generated'
            assert authorized.read_text().count('ssh-ed25519') == 1, 'no extra authorized key was enrolled'

            # 4. Live SSH login with the key from the config (fresh process, pinned host key).
            ssh = [profile['sshExecutable'], *profile['arguments']]
            assert run([*ssh, 'echo', 'config-key-ok'], timeout=30).stdout.decode().strip() == 'config-key-ok'

            # 5. Automatic update (B → C): the server publishes config-sync.json, the client applies it with its own key.
            sync_script = d / 'sync.ps1'
            sync_script.write_bytes(('﻿' + r'''param([string]$Repo,[string]$Root)
$ErrorActionPreference='Stop'
$env:REMOTEAGENTS_WIZARD_SESSION='1'
. (Join-Path $Repo 'build/Wizard.Common.ps1')
$script:WizardProgressFile=Join-Path $Root 'sync-progress.jsonl'
# Only the Windows Task Scheduler is replaced on Linux: the independent rollback task itself.
function Register-WizardRollback($Root,$Bundle,$Kind,$Session,$Task){Write-DiskUtf8 (Join-Path $Root 'state/rollback-armed') $Task}
function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm,[string]$ErrorAction)}
$first=Sync-WizardConfigSettings $Root $Repo ([pscustomobject]@{})
$second=Sync-WizardConfigSettings $Root $Repo ([pscustomobject]@{})
@{first=[bool]$first.changed;second=[bool]$second.changed;armed=(Test-Path (Join-Path $Root 'state/rollback-armed'));pending=(Test-Path (Join-Path $Root 'state/wizard-network.json'))}|ConvertTo-Json -Compress
''').replace('\n', '\r\n').encode())
            sync = lambda: json.loads(run([PWSH, '-NoProfile', '-NonInteractive', '-File', sync_script, REPO, root], env=env, timeout=300).stdout.decode().strip().splitlines()[-1])
            first = sync()
            assert first['armed'] and not first['pending'] and not first['second'], first
            second_key = keygen(d / 'host-next')
            settings['hostKeys'] = [host_pub, second_key]
            write_settings()
            b('sync')
            update = sync()
            assert update['first'] and not update['second'] and not update['pending'], update
            profile = json.loads(Path(config['transport']['profilePath']).read_text(encoding='utf-8-sig'))
            assert second_key in Path(profile['knownHostsPath']).read_text(), 'new host key pinned via config sync'
            assert run([*[profile['sshExecutable'], *profile['arguments']], 'true'], timeout=30).returncode == 0

            # 6. Revoke: the issued key no longer opens a NEW session.
            rows = [json.loads(x) for x in b('list', '--json').stdout.decode().splitlines()]
            assert len(rows) == 1, rows
            b('revoke', rows[0]['id'])
            denied = run([*ssh, 'true'], check=False, timeout=30)
            assert denied.returncode == 255 and b'Permission denied' in denied.stderr, denied.stderr
            assert 'ra-config:' not in authorized.read_text()
            print(json.dumps(dict(serverMs=result['serverMs'], serverStartToConnectionOkMs=result['serverStartToConnectionOkMs'],
                                  parallelOverlapMs=result['parallelOverlapMs'],
                                  sections={k: dict(ok=v['ok'], ms=v['endMs'] - v['startMs']) for k, v in sections.items()},
                                  totalSeconds=round(time.monotonic() - started, 1)), ensure_ascii=False))
            print('PASS: config export (B, enc1) → Parse/Unlock/Store/Materialize (A) → ConfigEngine (D) → Server/Connection/Vpn '
                  '(C, real SSH + sing-box) → login with the issued key → config sync (B→C) → revoke closes new logins')
        finally:
            (root / 'stop').write_text('stop')
            (root / 'state').mkdir(exist_ok=True)
            (root / 'state/transport.stop').write_text('stop')
            control = root / 'state/wizard-control'
            for session in (control.glob('*') if control.exists() else []):
                if session.is_dir():
                    (session / 'stop').write_text('stop')
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline and control.exists() and list(control.glob('*/ready.json')):
                time.sleep(.2)
            time.sleep(1)
            sshd.terminate()
            try:
                sshd.wait(5)
            except subprocess.TimeoutExpired:
                sshd.kill()
            log.close()


# ---------- Scenario «канал первым» (docs/TASK-CHANNEL.md, поток C) ----------
# Direct SSH is jammed like the owner's mobile network (real banner, then silence); the only working way is
# the server's VLESS-Reality channel behind a dumb TCP relay. Expected: Bootstrap brings the transport daemon up
# on `vless-relay-relay`, Server goes `proxy` through its SOCKS input, no TUN and no UAC.
SING_BOX = Path(os.environ.get('SING_BOX') or shutil.which('sing-box') or '/usr/bin/sing-box')
SNI = 'stand.test'


class Pipe(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve(server):
    threading.Thread(target=server.serve_forever, kwargs=dict(poll_interval=.1), daemon=True).start()
    return server


def pump(src, dst, counter):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            counter['bytes'] += len(data)
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            with contextlib.suppress(OSError):
                sock.shutdown(socket.SHUT_RDWR)


def relay(listen, target):
    """Dumb TCP relay like sparfum 77.91.72.183:8443: bytes both ways, no TLS, no knowledge of the protocol."""
    stats = dict(connections=0, bytes=0)

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            stats['connections'] += 1
            with socket.create_connection(target, 5) as up:
                t = threading.Thread(target=pump, args=(up, self.request, stats), daemon=True)
                t.start()
                pump(self.request, up, stats)
                t.join(30)
    server = serve(Pipe(listen, Handler))
    server.stats = stats
    return server


def jammer(listen, target):
    """Mobile network in front of the server: TCP and the real SSH banner pass, then silence forever."""
    stats = dict(connections=0, banners=0, swallowed=0)

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            stats['connections'] += 1
            with socket.create_connection(target, 5) as up:
                up.settimeout(5)
                banner = b''
                while not banner.endswith(b'\n') and len(banner) < 255:
                    chunk = up.recv(1)
                    if not chunk:
                        break
                    banner += chunk
                self.request.sendall(banner)
                stats['banners'] += banner.startswith(b'SSH-')
            # The upstream is dropped; the client is read and ignored until it gives up or the stand stops.
            self.request.settimeout(.5)
            while not getattr(self.server, 'stopping', False):
                try:
                    data = self.request.recv(65536)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not data:
                    break
                stats['swallowed'] += len(data)
    server = serve(Pipe(listen, Handler))
    server.stats = stats
    return server


def stop_server(server):
    server.stopping = True
    server.shutdown()
    server.server_close()


def channel_server(d, sshd_port):
    """sing-box VLESS-Reality on 127.0.0.1 only, its decoy TLS site, and the client channel JSON (secret vpn-channel).
    The channel's own address is 127.0.0.2: nothing listens there, so `vless-direct` cannot work, only the relay."""
    keys = dict(x.split(': ', 1) for x in run([SING_BOX, 'generate', 'reality-keypair']).stdout.decode().splitlines() if ': ' in x)
    pem = run([SING_BOX, 'generate', 'tls-keypair', SNI]).stdout.decode()
    cut = pem.index('-----BEGIN CERTIFICATE-----')
    (d / 'decoy.key').write_text(pem[:cut])
    (d / 'decoy.crt').write_text(pem[cut:])
    (d / 'decoy.key').chmod(0o600)
    uuid_, short_id = str(uuid.uuid4()), secrets.token_hex(4)
    vless_port, decoy_port = free_port(), free_port()
    server = dict(log=dict(level='warn', timestamp=False), inbounds=[
        dict(type='vless', tag='vless-in', listen='127.0.0.1', listen_port=vless_port,
             users=[dict(name='stand', uuid=uuid_, flow='xtls-rprx-vision')],
             tls=dict(enabled=True, server_name=SNI, reality=dict(enabled=True, handshake=dict(server='127.0.0.1', server_port=decoy_port),
                                                                    private_key=keys['PrivateKey'].strip(), short_id=[short_id]))),
        dict(type='http', tag='decoy', listen='127.0.0.1', listen_port=decoy_port,
             tls=dict(enabled=True, server_name=SNI, certificate_path=str(d / 'decoy.crt'), key_path=str(d / 'decoy.key')))],
        outbounds=[dict(type='direct', tag='direct')], route=dict(rules=[dict(inbound=['decoy'], action='reject')]))
    conf = d / 'vless-server.json'
    conf.write_text(json.dumps(server))
    conf.chmod(0o600)
    run([SING_BOX, 'check', '-c', conf])
    log = (d / 'vless-server.log').open('w')
    proc = subprocess.Popen([str(SING_BOX), 'run', '-c', str(conf)], stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    wait_port(vless_port, proc, d / 'vless-server.log')
    channel = dict(outbounds=[dict(type='vless', tag='server', server='127.0.0.2', server_port=vless_port, uuid=uuid_, flow='xtls-rprx-vision',
                                   tls=dict(enabled=True, server_name=SNI, utls=dict(enabled=True, fingerprint='chrome'),
                                            reality=dict(enabled=True, public_key=keys['PublicKey'].strip(), short_id=short_id)))])
    (d / 'channel.json').write_text(json.dumps(channel))
    (d / 'channel.json').chmod(0o600)
    return proc, log, vless_port, channel


def channel_client(d, channel, relay_port, sshd_port, socks_port):
    """Temporary sing-box client = the contract's daemon input: mixed `channel-socks`, route-options override to
    127.0.0.1:<sshd port>, outbound = the channel's VLESS sent to the relay (same as candidate vless-relay-relay)."""
    out = dict(channel['outbounds'][0], tag='vless-relay-relay', server='127.0.0.1', server_port=relay_port)
    conf = dict(log=dict(level='warn', timestamp=False),
                inbounds=[dict(type='mixed', tag='channel-socks', listen='127.0.0.1', listen_port=socks_port)],
                outbounds=[out],
                route=dict(rules=[dict(inbound=['channel-socks'], action='route-options', override_address='127.0.0.1', override_port=sshd_port),
                                  dict(inbound=['channel-socks'], outbound='vless-relay-relay')]))
    path = d / 'channel-client.json'
    path.write_text(json.dumps(conf))
    path.chmod(0o600)
    run([SING_BOX, 'check', '-c', path])
    log = (d / 'channel-client.log').open('w')
    proc = subprocess.Popen([str(SING_BOX), 'run', '-c', str(path)], stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    wait_port(socks_port, proc, d / 'channel-client.log')
    return proc, log


class ChannelStand:
    """Loopback server for the channel scenarios: sshd 127.0.0.1:P, jammer 127.0.0.2:P, VLESS-Reality, relay."""

    def __init__(self, d):
        self.d = d
        self.procs, self.logs, self.servers = [], [], []

    def __enter__(self):
        d = self.d
        self.server_home = d / 'server'
        (self.server_home / '.ssh').mkdir(parents=True, mode=0o700)
        self.server_home.chmod(0o755)
        self.bindir = self.server_home / '.local/bin'
        self.bindir.mkdir(parents=True)
        (self.bindir / 'systemctl').write_text('#!/bin/sh\nexit 0\n')
        (self.bindir / 'systemctl').chmod(0o700)
        self.conf_dir = self.server_home / '.config/remoteagents'
        self.conf_dir.mkdir(parents=True, mode=0o700)
        self.host_pub = keygen(d / 'host')
        self.port = free_port()
        self.authorized = self.server_home / '.ssh/authorized_keys'
        self.authorized.touch()
        write_sshd_conf(d, self.port, self.authorized, self.server_home, self.bindir)
        log = (d / 'sshd.log').open('w')
        self.logs.append(log)
        sshd = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(d / 'sshd.conf')], stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        self.procs.append(sshd)
        wait_port(self.port, sshd, d / 'sshd.log')
        self.jammer = jammer(('127.0.0.2', self.port), ('127.0.0.1', self.port))
        self.servers.append(self.jammer)
        proc, log, self.vless_port, self.channel = channel_server(d, self.port)
        self.procs.append(proc)
        self.logs.append(log)
        self.relay_port = free_port()
        self.relay = relay(('127.0.0.1', self.relay_port), ('127.0.0.1', self.vless_port))
        self.servers.append(self.relay)
        self.catalog = self.conf_dir / 'transport-catalog.json'
        self.catalog.write_text(json.dumps(dict(schema=1, entries=[], hops=[], relays=[dict(name='relay', host='127.0.0.1', port=self.relay_port)], cdn=[])))
        return self

    def __exit__(self, *exc):
        for server in self.servers:
            stop_server(server)
        for proc in reversed(self.procs):
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        for log in self.logs:
            log.close()
        kill_strays(self.d)


def kill_strays(d):
    """Processes that still mention the stand directory (daemon, its sing-box, ssh tunnels) are killed by PID."""
    mark = str(d).encode()
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit() or int(entry.name) == os.getpid():
            continue
        try:
            if mark in (entry / 'cmdline').read_bytes() or mark in (entry / 'environ').read_bytes():
                os.kill(int(entry.name), 9)
        except (OSError, ProcessLookupError):
            pass


def proxy_command(port):
    """ssh ProxyCommand through a local SOCKS: the program's own `--proxy-connect` (ProxyRelay) via the harness."""
    return f'"{DOTNET}" "{HARNESS}" --proxy-connect socks 127.0.0.1 {port} %h %p'


def ssh_base(key, known, port):
    return ['ssh', '-F', '/dev/null', '-p', str(port), '-l', USER, '-i', key, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
            '-o', f'UserKnownHostsFile={known}', '-o', 'GlobalKnownHostsFile=none', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=5']


def channel_parts():
    """Building blocks of the channel scenario, independent of streams A/B: stand, jammer, relay, VLESS through relay."""
    started = time.monotonic()
    os.umask(0o022)
    build_harness()
    numbers = {}
    with tempfile.TemporaryDirectory(prefix='ra-channel-parts-', delete=not os.environ.get('RA_E2E_KEEP')) as tmp:
        d = Path(tmp)
        t0 = time.monotonic()
        with ChannelStand(d) as stand:
            numbers['standUpMs'] = round((time.monotonic() - t0) * 1000)
            client = keygen(d / 'client')
            stand.authorized.write_text(client + '\n')
            known = d / 'known_hosts'
            known.write_text(f'[127.0.0.2]:{stand.port} {stand.host_pub}\n[127.0.0.1]:{stand.port} {stand.host_pub}\n')
            base = lambda host: [*ssh_base(d / 'client', known, stand.port), host]

            # 1. Stand: sshd itself answers a key login on 127.0.0.1:P.
            t = time.monotonic()
            assert run([*base('127.0.0.1'), 'echo', 'stand-ok'], timeout=30).stdout.decode().strip() == 'stand-ok'
            numbers['sshDirectStandMs'] = round((time.monotonic() - t) * 1000)

            # 2. Jammer: 127.0.0.2:P gives the real banner, then nothing. ssh hangs after «Remote protocol version».
            with socket.create_connection(('127.0.0.2', stand.port), 3) as s:
                s.settimeout(3)
                banner = s.recv(255)
                s.sendall(b'SSH-2.0-stand-probe\r\n')
                s.settimeout(2)
                try:
                    silent = s.recv(1) == b''
                except socket.timeout:
                    silent = True
            assert banner.startswith(b'SSH-2.0-OpenSSH') and silent, banner
            numbers['jammerBanner'] = banner.decode(errors='replace').strip()
            t = time.monotonic()
            try:
                p = subprocess.run([*base('127.0.0.2'), '-v', 'true'], capture_output=True, timeout=8, stdin=subprocess.DEVNULL)
                hung, err = False, p.stderr
            except subprocess.TimeoutExpired as e:
                hung, err = True, e.stderr or b''
            assert hung and b'Remote protocol version' in err, (hung, err[-2000:])
            numbers['sshThroughJammer'] = 'banner received, then silent; killed after %.1f s' % (time.monotonic() - t)

            # 3. The channel's own address (127.0.0.2:<vless>) is closed: vless-direct cannot work.
            try:
                socket.create_connection(('127.0.0.2', stand.vless_port), 2).close()
                direct_closed = False
            except OSError:
                direct_closed = True
            assert direct_closed, 'vless-direct must be unavailable on the stand'
            numbers['vlessDirect'] = 'refused'

            # 4. Relay: dumb TCP R -> VLESS port; a VLESS client through it reaches sshd (override to 127.0.0.1:P).
            socks = free_port()
            proc, log = channel_client(d, stand.channel, stand.relay_port, stand.port, socks)
            try:
                times = []
                for _ in range(3):
                    t = time.monotonic()
                    out = run([*base('127.0.0.2'), '-o', 'ProxyCommand=' + proxy_command(socks), 'echo', 'channel-ok'], timeout=30).stdout.decode().strip()
                    times.append(round((time.monotonic() - t) * 1000))
                    assert out == 'channel-ok', out
                numbers['sshViaChannelMs'] = times
                # Raw SOCKS (curl): banner of the real sshd comes through the channel, not the jammer.
                # telnet:// keeps the session open, so the time is bounded by --max-time (3 s), not by the channel.
                t = time.monotonic()
                p = subprocess.run(['curl', '-s', '--max-time', '3', '--socks5-hostname', f'127.0.0.1:{socks}', f'telnet://127.0.0.2:{stand.port}'],
                                   capture_output=True, timeout=10, stdin=subprocess.DEVNULL)
                assert p.stdout.startswith(b'SSH-2.0-OpenSSH'), p
                numbers['curlBannerViaChannelWithMaxTimeMs'] = round((time.monotonic() - t) * 1000)
            finally:
                proc.terminate()
                proc.wait(5)
                log.close()
            numbers['relay'] = dict(stand.relay.stats)
            numbers['jammer'] = dict(stand.jammer.stats)
            assert stand.relay.stats['connections'] >= 4 and stand.relay.stats['bytes'] > 0, stand.relay.stats
        numbers['totalSeconds'] = round(time.monotonic() - started, 1)
        print(json.dumps(numbers, ensure_ascii=False))
        print('PASS: channel parts — stand sshd, jammer (banner then silence), vless-direct closed, '
              'VLESS-Reality through the dumb relay with route-options override (ssh + curl)')


def build_harness():
    run([DOTNET, 'build', REPO / 'app/launcher/tests/PortableTests.csproj', '-c', 'Release', '-p:ConfigE2E=true', '--nologo', '-v:q'], timeout=300)


def main_channel():
    """Full scenario «канал первым». Needs streams A (engine) and B (`config export --vpn channel`)."""
    started = time.monotonic()
    os.umask(0o022)
    build_harness()
    with tempfile.TemporaryDirectory(prefix='ra-channel-e2e-', delete=not os.environ.get('RA_E2E_KEEP')) as tmp:
        d = Path(tmp)
        local = d / 'local'
        root = local / 'RemoteAgents'
        root.mkdir(parents=True)
        env = dict(os.environ, LOCALAPPDATA=str(local), REMOTEAGENTS_CONTROL_IDLE_SECONDS='30')
        try:
            with ChannelStand(d) as stand:
                export_cfg = d / 'config-export.json'
                settings = dict(schema=1, version=1, serverAddress='127.0.0.2', serverPort=stand.port, workerUser=USER, hostKeys=[stand.host_pub],
                                workerAuthorizedKeys=str(stand.authorized), stateDir=str(d / 'issued'), syncFile=str(stand.conf_dir / 'config-sync.json'),
                                nodeCatalog=str(stand.server_home / '.local/share/remote-agents-nodes'), catalogFile=str(stand.catalog),
                                authLog=[str(d / 'sshd.log')], routes=[{'kind': 'direct'}],
                                vpnBootstrap=dict(channelFile=str(d / 'channel.json'), vpn=dict(checkUrl=f'https://{SNI}/generate_204', dnsServer='127.0.0.1')))
                export_cfg.write_text(json.dumps(settings, ensure_ascii=False))
                export_cfg.chmod(0o600)

                # 1. Server (B): `config export --vpn channel`. Until B is merged the exporter has no `channel`:
                #    the same secrets from `--vpn on` with enabled=false are the contract's section (marked in the output).
                def export(vpn):
                    return run([sys.executable, '-I', REPO / 'server/remoteagents_config.py', '--config', export_cfg, 'export', '--name', 'Комп',
                                '--vpn', vpn, '--master-password-stdin'], check=False, input=(MASTER + '\r\n').encode())
                p = export('channel')
                issued_by = 'config export --vpn channel'
                if p.returncode == 2 and b'invalid choice' in p.stderr:
                    p = export('on')
                    issued_by = 'FALLBACK: config export --vpn on, vpn.enabled=false (stream B not merged)'
                assert p.returncode == 0, p.stderr.decode(errors='replace')[-2000:]
                config_doc = json.loads(p.stdout.decode())
                if issued_by.startswith('FALLBACK'):
                    config_doc['vpn']['enabled'] = False
                vpn = config_doc['vpn']
                assert vpn['enabled'] is False and vpn['checkUrl'] and vpn['dnsServer'], 'contract: vpn.enabled=false + checkUrl/dnsServer'
                assert vpn['bootstrap']['channel'] == {'secret': 'vpn-channel'}, vpn['bootstrap']
                assert vpn['bootstrap']['catalog']['relays'] == [dict(name='relay', host='127.0.0.1', port=stand.relay_port)], vpn['bootstrap']['catalog']
                assert vpn['bootstrap']['entries'] == {} and vpn['bootstrap']['hops'] == {}, vpn['bootstrap']
                assert config_doc['secrets']['vpn-channel'].startswith('enc1:') and MASTER not in p.stdout.decode()
                (d / 'issued.json').write_text(json.dumps(config_doc, ensure_ascii=False, indent=2) + '\n')

                # Stand-only transport knobs (unprivileged ports, Linux sing-box); everything else comes from the config.
                socks_port = free_port()
                (root / 'config.json').write_text(json.dumps(dict(schema=1, version=1, components={}, transport=dict(
                    singBoxPath=str(SING_BOX), bindPhysical=False, metered='false', probeTimeoutSec=8, stallSeconds=3,
                    sshPort=free_port(), syncPort=free_port(), apiPort=free_port(), channelSocksPort=socks_port))))
                # RemoteAgents.exe of the stand: the program's own --proxy-connect (ProxyRelay) for the `proxy` route.
                exe = root / 'RemoteAgents.exe'
                exe.write_text(f'#!/bin/sh\nexec "{DOTNET}" "{HARNESS}" "$@"\n')
                exe.chmod(0o700)

                # 2. Paste (A): Parse / Unlock / Store / Materialize.
                applied = json.loads(run([DOTNET, HARNESS, '--apply', root, d / 'issued.json'], env=dict(env, RA_E2E_MASTER=MASTER)).stdout)
                assert applied['missing'] == [] and applied['keyMaterialized'], applied

                # 3. «Запустить»: Bootstrap → Server → Connection/... at once.
                jammed_before = stand.jammer.stats['connections']
                p = run([DOTNET, HARNESS, '--run', root, REPO, PWSH], env=env, check=False, timeout=400)
                trace = p.stderr.decode(errors='replace')
                try:
                    result = json.loads(p.stdout.decode().strip().splitlines()[-1])
                except (ValueError, IndexError):
                    raise AssertionError('apply failed (no result)\n' + p.stdout.decode(errors='replace') + trace[-6000:])
                sections = result['sections']
                timing = dict(issuedBy=issued_by, startToServerOkMs=result.get('startToServerOkMs'), bootstrapMs=_ms(sections, 'bootstrap'),
                              serverMs=result['serverMs'], sections={k: dict(ok=v['ok'], ms=v['endMs'] - v['startMs'], summary=v['summary']) for k, v in sections.items()},
                              relay=dict(stand.relay.stats), jammer=dict(stand.jammer.stats))
                print(json.dumps(timing, ensure_ascii=False))
                assert result['plan'][:3] == ['bootstrap', 'server', 'connection'], result['plan']
                boot = result.get('bootstrap') or {}
                assert boot.get('ok') is True and boot.get('vpn') == 'channel' and boot.get('channel') == 'vless-relay-relay', \
                    ('Bootstrap: contract ok/vpn=channel/channel=vless-relay-relay', boot, trace[-4000:])
                assert boot.get('summary', '').startswith('Канал до сервера поднят: vless-relay-relay'), boot
                assert '[Bootstrap] · ' in trace, 'trace lines «· » (candidates, chosen, time) expected'
                assert sections['server']['ok'], (sections['server'], trace[-4000:])
                assert sections['connection']['ok'], (sections['connection'], trace[-4000:])
                assert all(s['ok'] for s in sections.values()), sections

                config = json.loads((root / 'config.json').read_text(encoding='utf-8-sig'))
                route = config['wizard']['serverRoute']
                assert route['used'] == 'proxy' and route['proxy'] == dict(type='socks', host='127.0.0.1', port=socks_port), route
                assert config['transport'].get('channelFirst') is True, 'transport.channelFirst'
                assert config['transport'].get('channelSocksPort', socks_port) == socks_port, 'channelSocksPort kept by «Связь»'
                profile = json.loads(Path(config['transport']['profilePath']).read_text(encoding='utf-8-sig'))
                assert f'--proxy-connect socks 127.0.0.1 {socks_port}' in profile.get('routeProxyCommand', ''), 'SSH goes through the channel'
                # No TUN, no UAC: neither the TUN worker, its session/config, nor the old internet preflight ran.
                for name in ('state/vpn-session.json', 'state/vpn-sing-box.json', 'state/bootstrap-internet-check.json', 'state/vpn-owner.json'):
                    assert not (root / name).exists(), name + ': TUN path must not run'
                assert not (config.get('vpn') or {}).get('enabled') and 'bootstrapTag' not in (config.get('vpn') or {}), config.get('vpn')
                status = json.loads((root / 'status/transport.json').read_text(encoding='utf-8-sig'))
                assert status.get('active') == 'vless-relay-relay', status.get('active')
                assert stand.relay.stats['connections'] > 0, 'traffic must pass the relay'

                # 4. Live SSH login with the issued key, as saved (ProxyCommand through the channel).
                t = time.monotonic()
                ssh = [profile['sshExecutable'], *profile['arguments']]
                assert run([*ssh, 'echo', 'config-key-ok'], timeout=30).stdout.decode().strip() == 'config-key-ok'
                timing.update(loginMs=round((time.monotonic() - t) * 1000), jammedConnections=stand.jammer.stats['connections'] - jammed_before,
                              totalSeconds=round(time.monotonic() - started, 1))
                print(json.dumps(timing, ensure_ascii=False))
                print('PASS: channel first — jammed direct SSH, Bootstrap on vless-relay-relay (no TUN/UAC), '
                      'Server via proxy 127.0.0.1:channelSocksPort, Connection ok, login with the issued key')
        finally:
            (root / 'stop').write_text('stop')
            (root / 'state').mkdir(exist_ok=True)
            (root / 'state/transport.stop').write_text('stop')
            control = root / 'state/wizard-control'
            for session in (control.glob('*') if control.exists() else []):
                if session.is_dir():
                    (session / 'stop').write_text('stop')
            time.sleep(1)
            kill_strays(d)


def _ms(sections, name):
    s = sections.get(name)
    return s['endMs'] - s['startMs'] if s else None


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='CONFIG end-to-end stand')
    parser.add_argument('--scenario', choices=('config', 'channel', 'channel-parts'), default=os.environ.get('RA_E2E_SCENARIO') or 'config',
                        help='config (default, as before) | channel («канал первым», needs streams A+B) | channel-parts (its building blocks)')
    {'config': main, 'channel': main_channel, 'channel-parts': channel_parts}[parser.parse_args().scenario]()
