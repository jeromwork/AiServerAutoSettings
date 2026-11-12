#!/usr/bin/env bash
# Every individual test has its own 300 s budget; a growing suite must not
# exhaust a shared timeout while all cases are progressing successfully.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export PYTHONPATH="$repo/server/tests${PYTHONPATH:+:$PYTHONPATH}"
while IFS= read -r case; do
  timeout 300 python3 -m unittest -v "$case"
done < <(python3 - "$repo/server/tests" <<'PY'
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

# Gateway owns its temporary HOME/systemd doubles and loopback 18xxx fixtures.
timeout 300 python3 -m unittest discover -s "$repo/server/tg-gateway" -p 'test_*.py' -v
