#!/usr/bin/env bash
# Every test runs in its own process with a 60 s execution budget. Chrome
# additionally allows 20 one-minute memory waits; full-suite startup has the same gate.
# Isolated: temporary HOME/authorized_keys, loopback sshd, no live services.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export PYTHONPATH="$repo/server/tests${PYTHONPATH:+:$PYTHONPATH}"
if ! python3 "$repo/server/tests/resource_guard.py"; then
  echo 'server/tests: SKIP full suite (memory guard)'
  exit 77
fi
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
  budget=60
  [[ $case != *test_chrome_* ]] || budget=1260 # includes up to 20 memory waits
  nice -n 10 timeout "$budget" python3 -m unittest -v "$case" < /dev/null
done
echo "server/tests: ${#cases[@]} тестов, все прошли"
# Server-only Telegram gateway import; loopback and disposable HOME, no live services.
timeout 60 python3 "$repo/server/tg-gateway/test_gateway.py" < /dev/null
timeout 120 python3 "$repo/server/tg-gateway/test_install.py" < /dev/null

# Slow, online Docker/systemd acceptance; opt in explicitly. Never uses host networking.
if [[ ${SERVER_AUTODEPLOY_E2E:-0} == 1 ]]; then
  python3 "$repo/server/tests/autodeploy/run.py"
fi

# Dedicated offline UI/systemd acceptance using a previously downloaded signed mirror.
if [[ ${SERVER_HAPPIER_WEB_E2E:-0} == 1 ]]; then
  python3 "$repo/server/tests/autodeploy/happier_web.py"
fi
