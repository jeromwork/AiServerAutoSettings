#!/usr/bin/env bash
# Isolated Linux fixtures; no real Disk/Mail. The unique runtime user unit is cleaned up.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
exec python3 "$repo/cloud/tests/test_server_cloud.py" "$@"
