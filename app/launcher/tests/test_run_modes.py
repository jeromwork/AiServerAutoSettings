#!/usr/bin/env python3
"""Exercise the runner's real orchestration block with small child processes, no heavy suites."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(__file__).with_name('run.sh').read_text()
start = source.index('(\n  wait_for_memory\n  timeout 60 python3 "$here/test_run_modes.py"')
end = source.index('trap cleanup EXIT', start)
block = source[start:end]
first_end = block.index(') > "$testdir/offline.log"')
block = '(\n  fixture offline "$OFFLINE_EXIT"\n' + block[first_end:]
block = block.replace('  bash "$repo/server/tests/run.sh"', '  fixture server "$SERVER_EXIT"')
fixture = '''import json, os, sys, time
from pathlib import Path
name, code = sys.argv[1:]
def event(state):
    with (Path(os.environ['TEST_ROOT'])/'events').open('a') as out:
        out.write(json.dumps([name,state,time.monotonic()])+'\\n')
event('start')
time.sleep(.2 if name=='offline' else .05)
event('end')
sys.exit(int(code))
'''
count = 0
for serial in ('0', '1'):
    for offline in ('0', '7'):
        for server in ('0', '9'):
            with tempfile.TemporaryDirectory(prefix='launcher-run-modes-') as tmp:
                root = Path(tmp)
                (root/'fixture.py').write_text(fixture)
                script = '''set -euo pipefail
testdir=$TEST_ROOT
cleanup() { :; }
wait_for_memory() { :; }
fixture() { "$PYTHON" "$testdir/fixture.py" "$@"; }
wait() { printf '%s\\n' "$1" >> "$testdir/waits"; builtin wait "$@"; }
''' + block + '\necho completed\n'
                env = dict(os.environ, TEST_ROOT=tmp, PYTHON=sys.executable,
                           LAUNCHER_TESTS_SERIAL=serial, OFFLINE_EXIT=offline, SERVER_EXIT=server)
                result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True, timeout=5)
                expected = 0 if offline == server == '0' else 1
                assert result.returncode == expected, (serial, offline, server, result.stderr)
                waits = (root/'waits').read_text().splitlines()
                assert len(waits) == 2 and len(set(waits)) == 2, ('each group must be waited exactly once', serial, waits)
                events = {tuple(item[:2]): item[2] for item in map(json.loads, (root/'events').read_text().splitlines())}
                assert len(events) == 4
                if serial == '1':
                    assert events['offline', 'end'] <= events['server', 'start'], events
                else:
                    assert events['server', 'start'] < events['offline', 'end'], events
                assert ('completed' in result.stdout) == (expected == 0)
                count += 1
print(f'PASS: {count} runner scenarios: both modes, success/failure of each group, one wait per PID')
