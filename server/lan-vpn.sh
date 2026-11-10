#!/usr/bin/env bash
# Owner-run only. No network operation happens merely by sourcing this file.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 -I "$SCRIPT_DIR/lan_vpn.py" "$@"
