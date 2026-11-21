#!/usr/bin/env bash
# Из корня worktree; общий timeout 120 обеспечивает gemini-bench.
set -euo pipefail
python3 -m py_compile server/agy_usage_scrape.py server/tests/test_agy_usage_scrape.py
actual=$(cd server && python3 -c "import agy_usage_scrape as s; print(s.parse_duration('6d 19h 37m'), s.parse_duration('163h 37m'), s.parse_duration('45s'), s.parse_duration('soon'))")
printf '%s\n' "$actual"
[[ "$actual" == '589020 589020 45 None' ]]
(cd server/tests && timeout 120 python3 -m unittest -v test_agy_usage_scrape test_happier_web.QuotaTests.test_agy_usage_scrape_parses_screen)
git status --short
