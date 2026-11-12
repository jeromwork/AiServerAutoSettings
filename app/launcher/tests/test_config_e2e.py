#!/usr/bin/env python3
"""Сквозной тест CONFIG на loopback-стенде (без root, временные HOME, настоящие OpenSSH/sshd/sing-box):

`remoteagents config export` (B, мастер-пароль) → текст конфига → ConfigBundle.Parse/Unlock/Store/Materialize (A)
→ оркестратор ConfigEngine (D) запускает настоящие действия Wizard.ps1 Server, Connection, Vpn (C); Bridge/Account/Disk —
стендовые (нужны Windows/Happier/Syncthing) → живой SSH-вход ключом из конфига → ConfigSync по снимку сервера (B→C)
→ `config revoke` → новый вход отвергнут.

Не трогает ~/.ssh, authorized_keys рабочего пользователя, службы, мост и Windows.
"""
import json
import os
from pathlib import Path
import pwd
import shutil
import socket
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parents[3]
PWSH = Path(os.environ.get('PWSH') or Path.home() / '.cache/pwsh-test/pwsh')
DOTNET = Path(os.environ.get('DOTNET') or Path.home() / '.dotnet/dotnet')
USER = pwd.getpwuid(os.getuid()).pw_name
MASTER = 'Мастер-пароль стенда 1'


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
            for _ in range(100):
                try:
                    with socket.create_connection(('127.0.0.1', port), .1):
                        break
                except OSError:
                    assert sshd.poll() is None, (d / 'sshd.log').read_text()
                    time.sleep(.03)

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


if __name__ == '__main__':
    main()
