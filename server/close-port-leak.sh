#!/usr/bin/env bash
# Owner-run sing-box rule repair, with a 5 minute rollback and explicit confirm.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 -I "$SCRIPT_DIR/close_port_leak.py" "$@"
