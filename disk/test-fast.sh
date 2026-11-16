#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# The caller owns heavy-tests.lock. Lock waiting is outside the execution budget.
if [[ ${1:-} != --bounded ]]; then
  exec timeout --kill-after=1 15 bash "$0" --bounded
fi
export DOTNET_PROCESSOR_COUNT=2 DOTNET_gcServer=0
export UseSharedCompilation=false DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER=1 MSBUILDDISABLENODEREUSE=1
export REMOTE_DISK_KEEP_POLL_MS=1
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
pwsh=${PWSH:-$HOME/.cache/pwsh-test/pwsh}
start=$(date +%s%N)
temp=$(mktemp -d "${REMOTE_DISK_TEST_TMP:-/dev/shm}/remote-disk-fast.XXXXXX")
trap 'rm -rf -- "$temp"' EXIT
export TMPDIR="$temp"
mkdir -p "$temp/home" "$temp/local" "$temp/user"
export HOME="$temp/home" LOCALAPPDATA="$temp/local" USERPROFILE="$temp/user"

export DOTNET="$dotnet"
python3 "$here/build-tests.py"
/usr/bin/time -f "Disk Python: %e s" python3 "$here/test-fast.py"
/usr/bin/time -f "Disk C#: %e s" "$dotnet" "$here/tests/bin/Release/net10.0/DiskTests.dll" --disk-fast
/usr/bin/time -f "Disk PowerShell: %e s" "$pwsh" -NoProfile -NonInteractive -File "$here/test-fast.ps1" < /dev/null
python3 - "$start" <<'PY'
import sys, time
elapsed = (time.time_ns() - int(sys.argv[1])) / 1e9
print(f'Disk fast: {elapsed:.3f} s (budget 10 s, hard timeout 15 s)', flush=True)
if elapsed > 10:
    raise SystemExit('FAIL: fast suite exceeded 10 s')
PY
