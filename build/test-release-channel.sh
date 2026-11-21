#!/usr/bin/env bash
# Offline only: the Python fixture puts fake git/gh/ssh/dotnet in PATH.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$here/test_release_channel.py"
