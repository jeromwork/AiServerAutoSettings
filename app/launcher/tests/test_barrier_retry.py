#!/usr/bin/env python3
"""Exercise the real retry wrapper with tiny commands and a simulated host load."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).with_name('run.sh').read_text()
START = SOURCE.index('# BEGIN barrier retry')
END = SOURCE.index('# END barrier retry.', START)
RETRY_BLOCK = SOURCE[START:END]
COMMAND = '''flaky x bash -c '
n=0
if [[ -f "$TEST_ROOT/count" ]]; then read -r n < "$TEST_ROOT/count"; fi
n=$((n+1))
printf "%s\\n" "$n" > "$TEST_ROOT/count"
echo "stdout attempt $n"
echo "stderr attempt $n" >&2
if [[ ${TEST_MODE:-fail} == once && $n -gt 1 ]]; then exit 0; fi
exit 7
'
'''


class BarrierRetryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='launcher-barrier-retry-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.logs = self.root/'retries'

    def run_shell(self, body=COMMAND, retries=None, mode='fail', load='0.00', custom=False):
        env = dict(os.environ, TEST_ROOT=str(self.root), TEST_MODE=mode, TEST_LOAD=load)
        env.pop('BARRIER_RETRIES', None)
        env.pop('BARRIER_RETRY_DIR', None)
        if retries is not None:
            env['BARRIER_RETRIES'] = str(retries)
        if custom:
            self.logs = self.root/'custom'/'attempts'
            env['BARRIER_RETRY_DIR'] = str(self.logs)
        # Supply deterministic load samples and advance Bash's clock instead of waiting.
        script = 'set -euo pipefail\nunset SECONDS\nSECONDS=0\ntestdir=$TEST_ROOT\n' + RETRY_BLOCK + '''
read() { builtin read "$@"; load1=$TEST_LOAD; }
sleep() { echo "$1" >> "$TEST_ROOT/sleeps"; SECONDS=$((SECONDS+$1)); }
''' + body
        return subprocess.run(['bash', '-c', script], env=env, capture_output=True,
                              text=True, timeout=5)

    def assert_attempts(self, result, codes, expected, load='0.00'):
        self.assertEqual(result.returncode, expected, result.stderr)
        self.assertEqual(int((self.root/'count').read_text()), len(codes))
        rows = [line.split('\t') for line in (self.logs/'retries.tsv').read_text().splitlines()]
        self.assertEqual(len(rows), len(codes), rows)
        for attempt, (row, code) in enumerate(zip(rows, codes), 1):
            self.assertEqual(len(row), 5, row)
            self.assertEqual(row[:3], ['x', str(attempt), str(code)])
            self.assertGreaterEqual(int(row[3]), 0)
            self.assertEqual(row[4], load)
            output = f'stdout attempt {attempt}\nstderr attempt {attempt}\n'
            self.assertEqual((self.logs/f'x.attempt{attempt}.log').read_text(), output)
            self.assertIn(output, result.stdout)
        self.assertEqual(len(list(self.logs.glob('*.log'))), len(codes))

    def test_fail_once_then_success(self):
        result = self.run_shell(retries=2, mode='once')
        self.assert_attempts(result, [7, 0], 0)
        self.assertEqual(result.stdout.count('RETRY[x]'), 1)
        self.assertIn('RETRY[x] attempt 1 failed (exit 7), retrying', result.stdout)
        self.assertFalse((self.root/'sleeps').exists())

    def test_exhausted_retries(self):
        result = self.run_shell(retries=2)
        self.assert_attempts(result, [7, 7, 7], 7)
        self.assertEqual(result.stdout.count('RETRY[x]'), 2)

    def test_default_has_one_attempt(self):
        result = self.run_shell()
        self.assert_attempts(result, [7], 7)
        self.assertNotIn('RETRY[', result.stdout)

    def test_success_has_no_retry_and_honors_environment(self):
        result = self.run_shell('flaky x env RETRY_VALUE=kept bash -c \'echo "$RETRY_VALUE"\'\n',
                                retries=2, custom=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.logs/'x.attempt1.log').read_text(), 'kept\n')
        self.assertEqual(len((self.logs/'retries.tsv').read_text().splitlines()), 1)
        self.assertNotIn('RETRY[', result.stdout)

    def test_failure_stops_background_group(self):
        body = '(\n' + COMMAND + '''echo must-not-run > "$TEST_ROOT/continued"
) > "$TEST_ROOT/group.log" 2>&1 &
pid=$!
code=0
wait "$pid" || code=$?
cat "$TEST_ROOT/group.log"
exit "$code"
'''
        result = self.run_shell(body, retries=2)
        self.assert_attempts(result, [7, 7, 7], 7)
        self.assertFalse((self.root/'continued').exists())

    def test_load_threshold_allows_four(self):
        result = self.run_shell(retries=1, mode='once', load='4.00')
        self.assert_attempts(result, [7, 0], 0, load='4.00')
        self.assertFalse((self.root/'sleeps').exists())

    def test_high_load_wait_is_bounded(self):
        result = self.run_shell(retries=1, mode='once', load='4.01')
        self.assert_attempts(result, [7, 0], 0, load='4.01')
        waits = [int(value) for value in (self.root/'sleeps').read_text().splitlines()]
        self.assertEqual(sum(waits), 120)
        self.assertTrue(all(0 < value <= 5 for value in waits))

    def test_default_logs_survive_cleanup(self):
        start = SOURCE.index('cleanup() {')
        cleanup = SOURCE[start:SOURCE.index('trap cleanup EXIT', start)]
        result = self.run_shell(cleanup + '''mkdir "$testdir/fixture"
flaky x echo saved
cleanup
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.logs/'x.attempt1.log').read_text(), 'saved\n')
        self.assertTrue((self.logs/'retries.tsv').is_file())
        self.assertFalse((self.root/'fixture').exists())

    def test_closed_retry_list(self):
        # Keep this list synchronized with section 0 of exe-build.md.
        expected = {'config-bootstrap', 'transport-events', 'transport-liveness',
                    'transport-daemon', 'engine-loopback', 'accounts', 'server'}
        names = re.findall(r'^\s*flaky[ \t]+([\w-]+)', SOURCE, re.MULTILINE)
        self.assertEqual(set(names), expected, 'closed retry list changed; review exe-build.md section 0')
        self.assertEqual(len(names), len(expected), 'each allowed group must be wrapped exactly once')


if __name__ == '__main__':
    unittest.main(verbosity=2)
