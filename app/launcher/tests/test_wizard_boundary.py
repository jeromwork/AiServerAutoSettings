"""Real dispatcher/shell boundaries in disposable homes; never use live SSH."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
PWSH = Path.home() / '.cache/pwsh-test/pwsh'


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


class WizardBoundaryTests(unittest.TestCase):
    def test_root_helper_is_idempotent_with_isolated_server_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'bin').mkdir()
            worker_home = root / 'worker'
            mock = r"""#!/usr/bin/env python3
import os,sys
from pathlib import Path
root=Path(os.environ['RA_FAKE_SERVER'])
name=Path(sys.argv[0]).name
args=sys.argv[1:]
if name=='id':
    if args==['-u']: print(0)
    elif args==['-u','remoteagents']: print(1234)
    elif args==['-gn','remoteagents']: print('remoteagents')
    else: sys.exit(0 if (root/'created').exists() else 1)
elif name=='getent': print('remoteagents:x:1234:1234::'+str(root/'worker')+':/bin/bash')
elif name=='useradd':
    with (root/'useradd-calls').open('a') as out:out.write('create\n')
    (root/'worker').mkdir();(root/'created').touch()
else:
    with (root/'service-calls').open('a') as out:out.write(name+' '+str(args)+'\n')
"""
            for name in ('id', 'getent', 'useradd', 'chown', 'loginctl', 'systemctl'):
                script = root / 'bin' / name
                script.write_text(mock)
                script.chmod(0o755)
            env = dict(os.environ, RA_FAKE_SERVER=tmp,
                       PATH=str(root/'bin')+os.pathsep+os.environ['PATH'],
                       ra_user='remoteagents', ra_key='ssh-ed25519 Zml4dHVyZQ== fixture')
            # Source includes CRLF as received from a Windows checkout, normalized at the boundary.
            source = (ROOT/'build/server-ssh-user.sh').read_text().replace('\n', '\r\n').replace('\r', '')
            for _ in range(2):
                result = subprocess.run(['bash', '-s'], input=source, text=True, env=env,
                                        capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, '')
            self.assertEqual((root/'useradd-calls').read_text().splitlines(), ['create'])
            keys = (worker_home/'.ssh/authorized_keys').read_text().splitlines()
            self.assertEqual([k for k in keys if k], [env['ra_key']])
            self.assertEqual((worker_home/'.ssh').stat().st_mode & 0o777, 0o700)
            self.assertEqual((worker_home/'.ssh/authorized_keys').stat().st_mode & 0o777, 0o600)
            self.assertIn('enable-linger', (root/'service-calls').read_text())

    def test_json_preserves_cyrillic_when_parent_console_is_ascii(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, LOCALAPPDATA=tmp, USERPROFILE=tmp)
            root = Path(tmp) / 'RemoteAgents'
            root.mkdir()
            (root / 'config.json').write_text('{}')
            command = "[Console]::OutputEncoding=[Text.Encoding]::ASCII;& " + quote(ROOT / 'build/Wizard.ps1') + ' -Home ' + quote(root) + ' -Action Catalog'
            result = subprocess.run([str(PWSH), '-NoProfile', '-NonInteractive', '-Command', command],
                                    env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 1)
            output = json.loads(result.stdout.decode('utf-8'))
            self.assertIn('Настройте SSH', output['reason'])

    def test_stale_scheduled_rollbacks_dispatch_as_noops(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'RemoteAgents'
            root.mkdir()
            for action in ('RollbackNetwork', 'RollbackBridge'):
                with self.subTest(action=action):
                    result = subprocess.run([str(PWSH), '-NoProfile', '-NonInteractive', '-File',
                                             str(ROOT / 'build/Wizard.ps1'), '-Home', str(root),
                                             '-Action', action, '-Session', 'obsolete-session'],
                                            env=dict(os.environ, LOCALAPPDATA=tmp), stdin=subprocess.DEVNULL,
                                            capture_output=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertEqual(result.stdout, b'')

    def test_server_ignore_replace_failure_keeps_complete_old_policy(self):
        # Load only the pure helper definitions, never server main/bootstrap.
        source = (ROOT / 'disk/server-disk.sh').read_text().split("<<'PY'\n", 1)[1].split('def main():', 1)[0]
        namespace = {}
        with patch.dict(os.environ, REMOTE_DISK_SCRIPT_DIR=str(ROOT / 'disk')):
            exec(compile(source, 'server-disk-helpers', 'exec'), namespace)
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            policy = (folder / '.stignore')
            previous = (ROOT / 'disk/stignore.txt').read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
            policy.write_bytes(previous)
            with patch.object(os, 'replace', side_effect=OSError('injected replace failure')):
                with self.assertRaises(OSError):
                    namespace['ignores'](folder, True)
            self.assertEqual(policy.read_bytes(), previous)
            self.assertEqual(list((folder / '.stfolder').iterdir()), [])

    def test_two_computers_upload_without_sharing_staging_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = dict(os.environ, LOCALAPPDATA=tmp, HOME=tmp)
            # Obtain the real cross-system payloads with a fake SSH transport.
            command = '. ' + quote(ROOT / 'build/Wizard.Common.ps1') + ';function Invoke-WizardSsh($Root,$Command,$InputText){[Console]::Write($InputText)};Send-WizardHelpers x ' + quote(ROOT)
            scripts = []
            for i in range(2):
                result = subprocess.run([str(PWSH), '-NoProfile', '-NonInteractive', '-Command', command],
                                        env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                text = result.stdout.decode('utf-8-sig').replace('\r', '')
                # Park both writers after staging the same always-installed helper.
                target = '$HOME/.local/share/remoteagents-wizard/server-wizard.sh'
                lines = text.splitlines()
                for n, line in enumerate(lines):
                    if 'base64 -d' in line and ('"' + target + '"') in line:
                        before, after = line.split('; mv -f -- ', 1)
                        lines[n] = before + f'; touch "$HOME/ready{i}"; while [ ! -f "$HOME/release" ]; do sleep 0.02; done; mv -f -- ' + after
                        break
                else:
                    self.fail('No helper upload found')
                scripts.append('\n'.join(lines) + '\n')
            script_files = []
            for i, script in enumerate(scripts):
                file = root / f'upload{i}.sh'; file.write_text(script); script_files.append(file)
            children = [subprocess.Popen(['bash', str(file)], env=env, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE) for file in script_files]
            try:
                deadline = time.monotonic() + 10
                while not all((root / f'ready{i}').exists() for i in range(2)):
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(.02)
                (root / 'release').touch()
                for child in children:
                    self.assertEqual(child.wait(10), 0, child.stderr.read().decode())
                for source, dest in [('build/server-wizard.sh', '.local/share/remoteagents-wizard/server-wizard.sh'),
                                     ('accounts/server-account.mjs', '.local/share/remoteagents-accounts/server-account.mjs')]:
                    self.assertEqual((root / dest).read_bytes(), (ROOT / source).read_bytes().replace(b'\r', b''))
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill(); child.wait(5)
                    for stream in (child.stdout, child.stderr):
                        stream.close()


if __name__ == '__main__':
    unittest.main()
