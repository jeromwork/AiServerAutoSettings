#!/usr/bin/env bash
# Owner runs this ONLY after acceptance. This script is never run by the test suite.
set -euo pipefail
if [[ $EUID != 0 || $# != 3 ]]; then
  echo 'Run as root: bash server/install-invite.sh /absolute/config.json /usr/local/lib/remoteagents /usr/local/bin/remoteagents' >&2
  exit 2
fi
config=$(realpath -- "$1")
prefix=$2
cli=$3
[[ $prefix = /* && $cli = /* && -f $config ]]
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install -d -m 755 -- "$prefix" "$(dirname -- "$cli")"
install -m 644 -- "$here/invite.py" "$prefix/invite.py"
install -m 644 -- "$here/invite_overlay.py" "$prefix/invite_overlay.py"
install -m 644 -- "$here/../transport/server-transport-catalog.py" "$prefix/server-transport-catalog.py"
# Absolute paths are emitted with POSIX shell quoting by Python, not interpolated code.
python3 - "$prefix/invite.py" "$config" "$cli" <<'PY'
import os, shlex, sys
from pathlib import Path
module, config, cli = sys.argv[1:]
Path(cli).write_text('#!/bin/sh\n[ "${1:-}" = invite ] || exit 2\nshift\nexec /usr/bin/python3 -I '+shlex.quote(module)+' --config '+shlex.quote(config)+' "$@"\n')
os.chmod(cli, 0o755)
PY
# No accounts, keys, sudoers, or services touched during code installation.
# The first invite create provisions the locked enrollment identity and narrow helper.
