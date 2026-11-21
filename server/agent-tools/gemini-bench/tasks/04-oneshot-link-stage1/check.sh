#!/usr/bin/env bash
# Из корня worktree; общий timeout 120 обеспечивает gemini-bench.
set -euo pipefail
python3 -m py_compile server/oneshot_link.py server/tests/test_oneshot_link.py
help=$(python3 server/oneshot_link.py --help)
printf '%s\n' "$help"
grep -c -- --bind <<< "$help"
(cd server/tests && timeout 120 python3 -m unittest -v test_oneshot_link)
git status --short
