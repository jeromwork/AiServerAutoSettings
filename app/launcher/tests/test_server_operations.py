"""Detached server operations (server-wizard.sh start/status/ensure/run) in a disposable HOME.

Fake bootstrap scripts stand in for the Happier/Syncthing installers; nothing is downloaded."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
FAKE_INSTALL = r"""#!/usr/bin/env bash
set -u
echo "$$" >> "$HOME/runs-$1"
printf '%s\n' '2/3 Скачиваю (тест)' > "${REMOTEAGENTS_STEP_FILE:-/dev/null}"
while [ ! -f "$HOME/release-$1" ]; do sleep 0.05; done
code=$(cat "$HOME/release-$1")
if [ "$code" != 0 ]; then echo 'curl: (28) Connection timed out token=abc123 after 120000 ms' >&2; fi
if [ "$1" = happier ] && [ "$code" = 0 ]; then mkdir -p "$HOME/.local/bin"; printf '#!/bin/sh\n' > "$HOME/.local/bin/happier"; chmod +x "$HOME/.local/bin/happier"; fi
exit "$code"
"""


class ServerOperationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ra-ops-')
        self.home = Path(self.tmp.name)
        h = self.home
        for rel in ('.local/share/remoteagents-wizard', '.local/share/remoteagents-accounts', '.local/share/remote-disk', '.local/bin'):
            (h / rel).mkdir(parents=True)
        # The window uploads LF; a CRLF checkout is normalized at that boundary.
        source = (ROOT / 'build/server-wizard.sh').read_bytes().replace(b'\r\n', b'\n')
        (h / '.local/share/remoteagents-wizard/server-wizard.sh').write_bytes(source)
        install = h / 'fake-install.sh'
        install.write_text(FAKE_INSTALL)
        (h / '.local/share/remoteagents-accounts/bootstrap.sh').write_text('exec bash "$HOME/fake-install.sh" happier\n')
        (h / '.local/share/remote-disk/server-disk.sh').write_text('[ "$1" = bootstrap ] || exit 9\nexec bash "$HOME/fake-install.sh" disk\n')
        (h / '.local/share/remoteagents-wizard/server-transport-catalog.py').write_text('print("{}")\n')
        # The helper puts ~/.local/bin first in PATH. Fake systemd-run --scope records the unit and execs the command (fds inherited).
        (h / '.local/bin/systemctl').write_text('#!/bin/sh\nexit 0\n')
        (h / '.local/bin/systemd-run').write_text('#!/bin/sh\necho "$@" >> "$HOME/systemd-run.log"\nwhile [ "${1#-}" != "$1" ]; do shift; done\nexec "$@"\n')
        for name in ('systemctl', 'systemd-run'):
            (h / '.local/bin' / name).chmod(0o755)
        self.env = dict(os.environ, HOME=str(h), PATH=os.environ['PATH'], XDG_RUNTIME_DIR=str(h))

    def tearDown(self):
        for op in ('happier', 'disk'):
            release = self.home / ('release-' + op)
            if not release.exists():
                release.write_text('0')
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and any(self.state(op)['state'] == 'running' for op in ('happier', 'disk')):
            time.sleep(0.05)
        self.tmp.cleanup()

    def call(self, *args, streamed=False):
        # streamed = how the window runs the read-only parts: `bash -s -- status …` with the script on stdin.
        script = self.home / '.local/share/remoteagents-wizard/server-wizard.sh'
        command = ['bash', '-s', '--', *args] if streamed else ['bash', str(script), *args]
        started = time.monotonic()
        result = subprocess.run(command, input=script.read_text() if streamed else None, text=True,
                                env=self.env, capture_output=True, timeout=20, cwd=self.home)
        self.assertLess(time.monotonic() - started, 10, 'server call must return at once')
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def state(self, op):
        return self.call('status', op, streamed=True)[op]

    def wait(self, op, state):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            current = self.state(op)
            if current['state'] == state:
                return current
            time.sleep(0.05)
        self.fail(op + ' did not reach ' + state)

    def runs(self, op):
        file = self.home / ('runs-' + op)
        return file.read_text().split() if file.exists() else []

    def test_detached_start_is_not_duplicated_and_finishes(self):
        self.assertEqual(self.state('happier')['state'], 'none')
        first = self.call('start', 'happier')['happier']
        self.assertEqual(first['state'], 'running')
        deadline = time.monotonic() + 5
        while not self.runs('happier') and time.monotonic() < deadline:
            time.sleep(0.05)
        for _ in range(3):
            self.assertEqual(self.call('start', 'happier')['happier']['state'], 'running')
        self.assertEqual(self.call('ensure', 'happier')['state'], 'running')
        time.sleep(0.3)
        self.assertEqual(len(self.runs('happier')), 1, 'second start must see the running operation')
        self.assertIn('--scope', (self.home / 'systemd-run.log').read_text())
        running = self.state('happier')
        self.assertEqual((running['stage'], running['stages']), (2, 3))
        self.assertEqual(running['step'], 'Скачиваю (тест)')
        (self.home / 'release-happier').write_text('0')
        done = self.wait('happier', 'finished')
        self.assertEqual(done['exitCode'], 0)
        self.assertEqual(done['reason'], '')
        self.assertGreaterEqual(done['elapsedSec'], 0)
        self.assertTrue(done['started'] and done['finished'])
        ready = self.call('ensure', 'happier')
        self.assertTrue(ready['ready'])
        self.assertEqual(len(self.runs('happier')), 1, 'ready Happier is not reinstalled')

    def test_failure_reason_is_public_and_retry_starts_again(self):
        self.call('start', 'disk')
        (self.home / 'release-disk').write_text('7')
        failed = self.wait('disk', 'failed')
        self.assertEqual(failed['exitCode'], 7)
        self.assertIn('Connection timed out', failed['reason'])
        self.assertNotIn('abc123', json.dumps(failed))
        (self.home / 'release-disk').unlink()
        self.assertEqual(self.call('start', 'disk')['disk']['state'], 'running')
        (self.home / 'release-disk').write_text('0')
        self.assertEqual(self.wait('disk', 'finished')['exitCode'], 0)
        self.assertEqual(len(self.runs('disk')), 2)

    def test_repair_starts_both_and_returns_at_once(self):
        # Without a user manager the plain setsid/nohup session is used.
        (self.home / '.local/bin/systemd-run').unlink()
        result = self.call('repair', '1', '1', '1')
        self.assertEqual(result['happier']['state'], 'running')
        self.assertEqual(result['disk']['state'], 'running')
        inspect = self.call('inspect', streamed=True)
        self.assertEqual(inspect['operations']['happier']['state'], 'running')

    def test_interrupted_operation_is_reported_failed(self):
        state = self.home / '.local/state/remoteagents-wizard'
        state.mkdir(parents=True)
        (state / 'happier.json').write_text(json.dumps({'schema': 1, 'op': 'happier', 'started': '2026-11-11T10:00:00Z', 'finished': None, 'exitCode': None}))
        (state / 'happier.lock').touch()
        current = self.state('happier')
        self.assertEqual(current['state'], 'failed')
        self.assertIn('прервана', current['reason'])

    def test_unknown_operation_is_rejected(self):
        script = self.home / '.local/share/remoteagents-wizard/server-wizard.sh'
        result = subprocess.run(['bash', str(script), 'start', '../x'], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
