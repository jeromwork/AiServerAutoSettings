#!/usr/bin/env bash
# Owner-run only. No network operation happens merely by sourcing this file.
set -euo pipefail
# OpenVPN runs route-up with an empty environment; nft/ip live in /usr/sbin.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 -I "$SCRIPT_DIR/lan_vpn.py" "$@"
