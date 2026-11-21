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

    def test_cli(self):
        self.write('app/A.cs', 'Thread.Sleep(10);\n')
        result = subprocess.run([sys.executable, '-I', str(SCRIPT), '--root', str(self.root)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('app/A.cs:1: Thread.Sleep(10);', result.stdout)

    def test_debt_errors(self):
        for source, header, section, expected in (('', '# count: 1', 'code', 'STALE DEBT'),
                ('Task.Delay(1);', '# count: 0', 'code', 'DEBT COUNT EXCEEDED'),
                ('Task.Delay(1);', '', 'code', 'DEBT HEADER MISSING'),
                ('Task.Delay(1);', '# count: 1', 'tests', 'NEW VIOLATION')):
            with self.subTest(expected=expected):
                self.write('app/A.cs', source)
                self.write('tests/timer-debt.txt', f'{header}\n[{section}]\napp/A.cs: Task.Delay(1);\n')
                self.assertTrue(any(expected in e for e in guard.scan(self.root)))

    def test_allowed_and_debt_sections(self):
        for path, text in {'app/A.cs': '// timer-ok: B — publishes tick events to bus\nnew Timer();',
                'build/a.ps1': 'Start-Sleep 1 # timer-ok: C — rollback when event is missing',
                'server/a.py': 'time.sleep(1) # timer-ok: D — operation hang protection only',
                'app/tests/a.cs': 'Task.Delay(1); // timer-ok: E — test hang protection only',
                'transport/a.ps1': 'Start-Sleep 1', 'tests/a.sh': 'sleep 1',
                'server/agent-tools/a.py': 'time.sleep(1)'}.items():
            self.write(path, text)
        self.write('tests/timer-debt.txt', '# count: 2\n[code]\ntransport/a.ps1: Start-Sleep 1 # W2\n[tests]\ntests/a.sh: sleep 1 # W4\n')
        self.assertEqual(guard.scan(self.root), [])

    def test_test_paths(self):
        paths = ('transport/test-x.ps1', 'transport/test-collect-netstate.ps1', 'server/tg-gateway/test_gateway.py',
                 'app/RemoteAgents.Tests/A.cs', 'app/launcher/UpdateSelfTests.cs', 'app/launcher/UpgradeSelfTests.cs',
                 'server/gateway_test.py', 'app/test/A.cs', 'app/tests/A.cs')
        for path in paths:
            site, comment = ('Task.Delay(1);', '//') if path.endswith('.cs') else (
                ('time.sleep(1)', '#') if path.endswith('.py') else ('Start-Sleep 1', '#'))
            for category in ('E', 'C'):
                with self.subTest(path=path, category=category):
                    self.write(path, f'{site} {comment} timer-ok: {category} — test hang protection only\n')
                    self.assertEqual(bool(guard.scan(self.root)), category != 'E')
            (self.root / path).unlink()

    def test_duplicate_debt(self):
        for sites, entries in ((2, 1), (1, 2), (2, 2), (0, 2)):
            with self.subTest(sites=sites, entries=entries):
                self.write('app/A.cs', 'Task.Delay(1);\n' * sites)
                self.write('tests/timer-debt.txt', f'# count: {entries}\n[code]\n' + 'app/A.cs: Task.Delay(1);\n' * entries)
                errors = guard.scan(self.root)
                self.assertEqual(len(errors), abs(sites - entries))
                self.assertTrue(all(('NEW VIOLATION' if sites > entries else 'STALE DEBT') in e for e in errors))

    def test_annotation_context(self):
        for ext, site, prefixes in (('.cs', 'new Timer();', ('//', '/*', '#', 'var x = 1; //')),
                ('.py', 'time.sleep(1)', ('#', '//', 'x = 1 #')), ('.sh', 'sleep 1', ('#', '//')),
                ('.ps1', 'Start-Sleep 1', ('#', '<#', '//', 'x = 1 #'))):
            for prefix in prefixes:
                with self.subTest(ext=ext, prefix=prefix):
                    ending = ' */' if prefix == '/*' else ' #>' if prefix == '<#' else ''
                    self.write('app/A' + ext, f'{prefix} timer-ok: B — publishes tick events to bus{ending}\n{site}\n')
                    self.assertEqual(guard.scan(self.root) == [], prefix in (('//', '/*') if ext == '.cs' else ('#', '<#')))
            (self.root / ('app/A' + ext)).unlink()
        for annotation in ('C — short', 'E — long enough justification', 'A — long enough justification'):
            self.write('app/A.cs', f'Task.Delay(1); // timer-ok: {annotation}\n')
            self.assertTrue(guard.scan(self.root))
        self.write('app/A.cs', '/* timer-ok: B — publishes tick events to bus */ x();\nnew Timer();\n')
        self.assertTrue(guard.scan(self.root))

    def test_literals_and_comments(self):
        fixtures = {'.cs': ['var x = "Task.Delay(1)";', '// Thread.Sleep(10);', 'x(); // Thread.Sleep(10);',
                            'var x = @"Task.Delay(1) ""Thread.Sleep(10)""";', 'var x = "\\\"Task.Delay(1)";'],
                    '.py': ['fixture = "time.sleep(1)"', '# time.sleep(1)'],
                    '.ps1': ["Write-Output 'Start-Sleep 1'", '<# Start-Sleep 1 #>'],
                    '.sh': ["printf 'sleep 1'", "printf '%s\\n' 'sleep 1'"]}
        for ext, lines in fixtures.items():
            self.write('app/A' + ext, '\n'.join(lines))
        self.assertEqual(guard.scan(self.root), [])
        for ext, site in (('.cs', 'Task.Delay(1); Log("timer-ok: B — publishes tick events to bus");'),
                ('.ps1', 'Start-Sleep 1; Write-Output "timer-ok: B — publishes tick events to bus"'),
                ('.py', 'time.sleep(1); x = "timer-ok: B — publishes tick events to bus"'),
                ('.sh', 'sleep 1; echo "timer-ok: B — publishes tick events to bus"'),
                ('.cs', 'Log("timer-ok: B — publishes tick events to bus");\nTask.Delay(1);'),
                ('.cs', '/* note */ Thread.Sleep(10);')):
            with self.subTest(site=site):
                self.write('app/A' + ext, site)
                self.assertEqual(len(guard.scan(self.root)), 1)
                (self.root / ('app/A' + ext)).unlink()

    def test_executable_interpolations(self):
        fixtures = {
            '.sh': ['echo "$(sleep 1)"', 'echo "`sleep 1`"', 'echo `sleep 1`',
                    'echo prefix`sleep 1`', 'echo x$(sleep 1)y', 'echo "pre`sleep 1`post"',
                    'echo "$(echo "$(sleep 1)")"', 'echo "$(echo "safe") $(sleep 1)"'],
            '.ps1': ['"a$(Start-Sleep 1)b"', 'Write-Output "$(Start-Sleep 1)"',
                     'Write-Output "$(if ($true) { Start-Sleep 1 })"'],
            '.py': ['text = f"{time.sleep(1)}"', "text = f'{time.sleep(1)}'",
                    'f"a{time.sleep(1)}b"',
                    'text = f"{dict(x=time.sleep(1))}"', 'text = rf"{time.sleep(1)}"',
                    'text = f"{value:{time.sleep(1)}}"', 'text = f"{{{time.sleep(1)}}}"',
                    'text = f"{len("safe")} {time.sleep(1)}"'],
            '.cs': ['var text = $"{Task.Delay(1)}";', 'var text = $@"{Task.Delay(1)}";',
                    '$"a{Task.Delay(1)}b"',
                    'var text = @$"{Task.Delay(1)}";', 'var text = $"{{literal}} {Task.Delay(1)}";',
                    'var text = $"{F("safe")} {Task.Delay(1)}";',
                    'var url = "http://example"; Task.Delay(1);']}
        for ext, lines in fixtures.items():
            for line in lines:
                with self.subTest(line=line):
                    self.write('app/A' + ext, line + '\r\n')
                    self.assertEqual(len(guard.scan(self.root)), 1)
            (self.root / ('app/A' + ext)).unlink()

    def test_interpolation_literal_text(self):
        fixtures = {
            '.sh': ['echo "sleep 1"', "echo '$(sleep 1)'", "echo '`sleep 1`'",
                    "echo 'prefix`sleep 1`'", "echo 'x$(sleep 1)y'",
                    r'echo "\$(sleep 1)"', r'echo "\`sleep 1\`"', 'echo "$(echo \'sleep 1\')"'],
            '.ps1': ['Write-Output "Start-Sleep 1"', "Write-Output '$(Start-Sleep 1)'",
                     "'a$(Start-Sleep 1)b'",
                     'Write-Output "`$(Start-Sleep 1)"', 'Write-Output "$(echo \'Start-Sleep 1\')"'],
            '.py': ['text = f"time.sleep(1) {value}"', 'text = f"{{time.sleep(1)}}"',
                    'text = f"{value:time.sleep(1)}"',
                    'text = "{time.sleep(1)}"', 'text = f"{str(\'time.sleep(1)\')}"'],
            '.cs': ['var text = $"Task.Delay(1) {value}";', 'var text = $"{{Task.Delay(1)}}";',
                    'var text = $"{value:Task.Delay(1)}";',
                    'var text = $@"{{Task.Delay(1)}}";', 'var text = $"{F(\'x\', \"Task.Delay(1)\")}";',
                    'var url = "http://example";']}
        for ext, lines in fixtures.items():
            self.write('app/A' + ext, '\n'.join(lines))
        self.assertEqual(guard.scan(self.root), [])

    def test_real_shell_substitutions(self):
        lines = (SCRIPT.parent.parent / 'build/server-ssh-user.sh').read_text().splitlines()
        self.write('build/fixture.sh', '\n'.join(lines[index - 1] for index in (35, 60)))
        errors = guard.scan(self.root)
        self.assertEqual(len(errors), 2)
        for index in (35, 60):
            self.assertTrue(any(lines[index - 1].strip() in error for error in errors))

    def test_allowed_does_not_consume_debt(self):
        site = 'Task.Delay(1);\n'
        allowed = '// timer-ok: D — operation hang protection only\n' + site
        self.write('tests/timer-debt.txt', '# count: 1\n[code]\napp/A.cs: Task.Delay(1);\n')
        for count in (0, 1, 2):
            for source in (allowed + site * count, site * count + allowed):
                with self.subTest(count=count, source=source):
                    self.write('app/A.cs', source)
                    errors = guard.scan(self.root)
                    self.assertEqual(len(errors), max(0, count - 1))
                    self.assertTrue(all('NEW VIOLATION' in e for e in errors))

    def test_patterns(self):
        examples = {'.cs': ['Thread.Sleep(1)', 'Task.Delay(1)', 'new Timer()', 'new System.Threading.Timer(x)', 'PeriodicTimer(x)', 'file.LastWriteTime', 'System.Timers.Timer', 'DispatcherTimer', 'Forms.Timer', 'GetLastWriteTime(x)', 'maxAgeSec', 'MaxAge', 'isStale', '(UtcNow - t).TotalSeconds'],
                    '.ps1': ['Start-Sleep 1', '[Threading.Thread]::Sleep(1)', 'LastWriteTime', 'TotalSeconds -ge 1', 'updatedAt'],
                    '.py': ['time.sleep(1)', 'asyncio.sleep(1)', 'threading.Timer(1, f)', 'st_mtime', 'getmtime(x)'],
                    '.sh': ['sleep 1', 'stat -c %Y file', 'stat -c "%Y" file', 'find . -mmin +1', 'find . -newer stamp']}
        for ext, lines in examples.items():
            for line in lines:
                with self.subTest(line=line):
                    self.write('app/A' + ext, line)
                    self.assertTrue(any(line in e for e in guard.scan(self.root)))
            (self.root / ('app/A' + ext)).unlink()

if __name__ == '__main__':
    unittest.main()
