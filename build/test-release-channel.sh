#!/usr/bin/env bash
# Offline only: release fixtures mock git/gh/ssh/dotnet; the ignore check uses real Git.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$here/test_release_channel.py"
