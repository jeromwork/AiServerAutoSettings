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
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertIn(message, result.stdout)

    def test_new_site(self):
        self.write('app/A.cs', 'Thread.Sleep(10);\n')
        self.cli(1, 'app/A.cs:1: Thread.Sleep(10);')

    def test_stale_debt(self):
        self.write('tests/timer-debt.txt', '# count: 1\n[code]\napp/A.cs: Task.Delay(1);\n')
        self.cli(1, 'STALE DEBT ENTRY')

    def test_debt_count(self):
        self.write('server/a.py', 'time.sleep(1)\n')
        self.write('tests/timer-debt.txt', '# count: 0\n[code]\nserver/a.py: time.sleep(1)\n')
        self.cli(1, 'DEBT COUNT EXCEEDED')

    def test_allowed_and_debt_sections(self):
        self.write('app/A.cs', '// timer-ok: B — publishes tick events to bus\nnew Timer();\n')
        self.write('build/a.ps1', 'Start-Sleep 1 # timer-ok: C — rollback when event is missing\n')
        self.write('server/a.py', 'time.sleep(1) # timer-ok: D — operation hang protection only\n')
        self.write('app/tests/a.cs', 'Task.Delay(1); // timer-ok: E — test hang protection only\n')
        self.write('transport/a.ps1', 'Start-Sleep 1\n')
        self.write('tests/a.sh', 'sleep 1\n')
        self.write('tests/timer-debt.txt', '# count: 2\n[code]\ntransport/a.ps1: Start-Sleep 1 # W2\n[tests]\ntests/a.sh: sleep 1 # W4\n')
        self.write('server/agent-tools/a.py', 'time.sleep(1)\n')
        self.cli(0, 'Timer Guard: OK')

    def test_invalid_annotation_and_wrong_section(self):
        for annotation in ('C — short', 'E — long enough justification'):
            self.write('app/A.cs', f'Task.Delay(1); // timer-ok: {annotation}\n')
            self.assertTrue(guard.scan(self.root))
        self.write('app/A.cs', '')
        self.write('tests/a.py', 'time.sleep(1)\n')
        self.write('tests/timer-debt.txt', '# count: 1\n[code]\ntests/a.py: time.sleep(1)\n')
        self.assertTrue(any('NEW VIOLATION' in e for e in guard.scan(self.root)))
        self.assertTrue(any('STALE DEBT' in e for e in guard.scan(self.root)))

    def test_patterns(self):
        examples = {'.cs': ['Thread.Sleep(1)', 'Task.Delay(1)', 'new Timer()', 'System.Timers.Timer', 'DispatcherTimer', 'Forms.Timer', 'GetLastWriteTime(x)', 'maxAgeSec', 'MaxAge', 'isStale', '(UtcNow - t).TotalSeconds'],
                    '.ps1': ['Start-Sleep 1', '[Threading.Thread]::Sleep(1)', 'LastWriteTime', 'TotalSeconds -ge 1', 'updatedAt'],
                    '.py': ['time.sleep(1)', 'st_mtime', 'getmtime(x)'], '.sh': ['sleep 1']}
        for extension, lines in examples.items():
            for line in lines:
                with self.subTest(line=line):
                    self.write('app/example' + extension, line + '\n')
                    self.assertTrue(any(line in e for e in guard.scan(self.root)))
                    (self.root / ('app/example' + extension)).unlink()


if __name__ == '__main__':
    unittest.main()
