#!/usr/bin/env bash
# Without arguments: build and publish on this server. Optional destination supports /tmp tests.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ $# -eq 0 ]]; then
  "$here/build-exe.sh"
  out=${REMOTEAGENTS_BUILD_OUT:-$here/out}
  exec python3 "$here/bundle.py" publish "$out/bundle.zip" "${REMOTEAGENTS_DIST:-$HOME/.local/share/remote-agents/dist}" --launcher "$out/RemoteAgents.exe"
fi
exec python3 "$here/bundle.py" publish "$@"
