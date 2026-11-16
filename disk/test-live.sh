#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ ${1:-} != --bounded ]]; then
  exec timeout --kill-after=2 60 bash "$0" --bounded
fi
# Every HOME/engine in this suite is disposable. Never use installed state.
export DOTNET_PROCESSOR_COUNT=2 DOTNET_gcServer=0
export UseSharedCompilation=false DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER=1 MSBUILDDISABLENODEREUSE=1
export REMOTE_DISK_API_READ_TIMEOUT_S=1 REMOTE_DISK_API_WRITE_TIMEOUT_S=5
export REMOTE_DISK_STARTUP_ATTEMPTS=30 REMOTE_DISK_RECONNECT_INTERVAL_S=1
export REMOTE_DISK_KEEP_TIMEOUT_MS=3000 REMOTE_DISK_KEEP_POLL_MS=10
export REMOTE_DISK_WATCHER_DELAY_MS=10 REMOTE_DISK_WATCHER_DELAY_S=.01
export REMOTE_DISK_LIVE_WAIT_S=5
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
export DOTNET="$dotnet"
python3 "$here/build-tests.py"
exec python3 "$here/test-live.py"
