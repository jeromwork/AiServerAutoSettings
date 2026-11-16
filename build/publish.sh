#!/usr/bin/env bash
# Without arguments: build and publish on this server. Optional destination supports /tmp tests.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Explicit /tmp destinations are offline packaging tests; every real publication requires main.
if [[ $# -ge 2 && $(realpath -m -- "$2") == /tmp/* ]]; then
  exec python3 "$here/bundle.py" publish "$@"
fi
"$here/require-main.sh"
if [[ $# -eq 0 ]]; then
  echo 'Полная выкладка: build/release.sh SSH-алиас [remote-dist]' >&2
  exit 2
fi
exec python3 "$here/bundle.py" publish "$@"
