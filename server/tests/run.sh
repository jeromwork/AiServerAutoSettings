#!/usr/bin/env bash
# Every individual test runs in its own process with a 60 s budget; the whole suite
# is expected to finish under `timeout 120 bash server/tests/run.sh`.
# Isolated: temporary HOME/authorized_keys, loopback sshd, no live services.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export PYTHONPATH="$repo/server/tests${PYTHONPATH:+:$PYTHONPATH}"
mapfile -t cases < <(python3 - "$repo/server/tests" <<'PY'
import sys, unittest
suite = unittest.TestLoader().discover(sys.argv[1])
def cases(group):
    for test in group:
        if isinstance(test, unittest.TestSuite):
            yield from cases(test)
        else:
            yield test.id()
print('\n'.join(cases(suite)))
PY
)
(( ${#cases[@]} > 0 )) || { echo 'server/tests: тесты не найдены' >&2; exit 1; }
for case in "${cases[@]}"; do
  # A child (ssh) must never read the runner's stdin.
  timeout 60 python3 -m unittest -v "$case" < /dev/null
done
echo "server/tests: ${#cases[@]} тестов, все прошли"
