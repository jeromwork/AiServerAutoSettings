#!/usr/bin/env bash
# Install/update only as the working service user; state lives outside the checkout.
set -euo pipefail
umask 077
export PATH="${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec /usr/bin/python3 -I "$SCRIPT_DIR/tg_gateway_setup.py" "$@"
