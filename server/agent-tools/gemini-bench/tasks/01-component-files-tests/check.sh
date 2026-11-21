#!/usr/bin/env bash
# Из корня worktree; общий timeout 120 обеспечивает gemini-bench.
set -euo pipefail
python3 -m py_compile server/tests/test_component_files.py
git diff --quiet -- server/component_files.py
git diff --cached --quiet -- server/component_files.py
(cd server/tests && timeout 120 python3 -m unittest -v test_component_files)
git status --short
