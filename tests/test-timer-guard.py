#!/usr/bin/env python3
"""Temporary fixtures only: no real timers, network, or repository scan."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('timer-guard.py')
spec = importlib.util.spec_from_file_location('timer_guard', SCRIPT)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class TimerGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding='utf-8')

    def cli(self, code, message):
        result = subprocess.run([sys.executable, '-I', str(SCRIPT), '--root', str(self.root)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertIn(message, result.stdout)

    def assert_error(self, message):
        self.assertTrue(any(message in error for error in guard.scan(self.root)))

    def test_new_site(self):
        self.write('app/A.cs', 'Thread.Sleep(10);\n')
        self.cli(1, 'app/A.cs:1: Thread.Sleep(10);')

    def test_stale_debt(self):
        self.write('tests/timer-debt.txt', '# count: 1\n[code]\napp/A.cs: Task.Delay(1);\n')
        self.assert_error('STALE DEBT ENTRY')

    def test_debt_count(self):
        self.write('server/a.py', 'time.sleep(1)\n')
        self.write('tests/timer-debt.txt', '# count: 0\n[code]\nserver/a.py: time.sleep(1)\n')
        self.assert_error('DEBT COUNT EXCEEDED')

    def test_allowed_and_debt_sections(self):
        self.write('app/A.cs', '// timer-ok: B — publishes tick events to bus\nnew Timer();\n')
        self.write('build/a.ps1', 'Start-Sleep 1 # timer-ok: C — rollback when event is missing\n')
        self.write('server/a.py', 'time.sleep(1) # timer-ok: D — operation hang protection only\n')
        self.write('app/tests/a.cs', 'Task.Delay(1); // timer-ok: E — test hang protection only\n')
        self.write('transport/a.ps1', 'Start-Sleep 1\n')
        self.write('tests/a.sh', 'sleep 1\n')
        self.write('tests/timer-debt.txt', '# count: 2\n[code]\ntransport/a.ps1: Start-Sleep 1 # W2\n[tests]\ntests/a.sh: sleep 1 # W4\n')
        self.write('server/agent-tools/a.py', 'time.sleep(1)\n')
        self.assertEqual(guard.scan(self.root), [])

    def test_invalid_annotation_and_wrong_section(self):
        for annotation in ('C — short', 'E — long enough justification'):
            self.write('app/A.cs', f'Task.Delay(1); // timer-ok: {annotation}\n')
            self.assertTrue(guard.scan(self.root))
        self.write('app/A.cs', '')
        self.write('tests/a.py', 'time.sleep(1)\n')
        self.write('tests/timer-debt.txt', '# count: 1\n[code]\ntests/a.py: time.sleep(1)\n')
        self.assertTrue(any('NEW VIOLATION' in e for e in guard.scan(self.root)))
        self.assertTrue(any('STALE DEBT' in e for e in guard.scan(self.root)))

    def test_test_paths(self):
        paths = ('transport/test-x.ps1', 'transport/test-collect-netstate.ps1',
                 'server/tg-gateway/test_gateway.py', 'app/RemoteAgents.Tests/A.cs',
                 'app/launcher/UpdateSelfTests.cs', 'app/launcher/UpgradeSelfTests.cs',
                 'server/gateway_test.py', 'app/test/A.cs', 'app/tests/A.cs')
        for path in paths:
            site = 'Start-Sleep 1' if path.endswith('.ps1') else (
                'time.sleep(1)' if path.endswith('.py') else 'Task.Delay(1);')
            for category in ('E', 'C'):
                with self.subTest(path=path, category=category):
                    self.write(path, f'{site} // timer-ok: {category} — test hang protection only\n')
                    errors = guard.scan(self.root)
                    if category == 'E':
                        self.assertEqual(errors, [])
                    else:
                        self.assertTrue(any('NEW VIOLATION' in e for e in errors))
                    (self.root / path).unlink()

    def test_duplicate_debt(self):
        site = 'Task.Delay(1);\n'
        entry = 'app/A.cs: Task.Delay(1);\n'
        for sites, entries, expected in ((2, 1, 'NEW VIOLATION'),
                                         (1, 2, 'STALE DEBT ENTRY'),
                                         (2, 2, None), (0, 2, 'STALE DEBT ENTRY')):
            with self.subTest(sites=sites, entries=entries):
                self.write('app/A.cs', site * sites)
                self.write('tests/timer-debt.txt', f'# count: {entries}\n[code]\n' + entry * entries)
                errors = guard.scan(self.root)
                if expected:
                    self.assertEqual(len(errors), abs(sites - entries))
                    self.assertTrue(all(expected in e for e in errors))
                else:
                    self.assertEqual(errors, [])

    def test_previous_annotation_requires_comment(self):
        for prefix, allowed in (('//', True), ('#', True),
                                ('var x = 1; //', False), ('x = 1 #', False)):
            with self.subTest(prefix=prefix):
                self.write('app/A.cs', f'{prefix} timer-ok: B — publishes tick events to bus\nnew Timer();\n')
                errors = guard.scan(self.root)
                self.assertEqual(bool(errors), not allowed)

    def test_previous_block_comment_with_trailing_code(self):
        self.write('app/A.cs', '/* timer-ok: B — publishes tick events to bus */ x();\nnew Timer();\n')
        self.assert_error('NEW VIOLATION')

    def test_patterns(self):
        examples = {'.cs': ['Thread.Sleep(1)', 'Task.Delay(1)', 'new Timer()', 'new System.Threading.Timer(x)', 'PeriodicTimer(x)', 'file.LastWriteTime', 'System.Timers.Timer', 'DispatcherTimer', 'Forms.Timer', 'GetLastWriteTime(x)', 'maxAgeSec', 'MaxAge', 'isStale', '(UtcNow - t).TotalSeconds'],
                    '.ps1': ['Start-Sleep 1', '[Threading.Thread]::Sleep(1)', 'LastWriteTime', 'TotalSeconds -ge 1', 'updatedAt'],
                    '.py': ['time.sleep(1)', 'asyncio.sleep(1)', 'threading.Timer(1, f)', 'st_mtime', 'getmtime(x)'], '.sh': ['sleep 1', 'stat -c %Y file', 'stat -c \"%Y\" file', 'find . -mmin +1', 'find . -newer stamp']}
        for extension, lines in examples.items():
            for line in lines:
                with self.subTest(line=line):
                    self.write('app/example' + extension, line + '\n')
                    self.assertTrue(any(line in e for e in guard.scan(self.root)))
                    (self.root / ('app/example' + extension)).unlink()


if __name__ == '__main__':
    unittest.main()
