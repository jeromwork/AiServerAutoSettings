#!/usr/bin/env bash
# Offline, fail-fast; compile the LanTests target separately before this <=10 s run.
set -euo pipefail
if [[ ${1:-} != --inner ]]; then exec timeout 10 bash "$0" --inner; fi
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
pwsh=${PWSH:-$HOME/.cache/pwsh-test/pwsh}
cd "$repo"
python3 server/tests/test_lan_share.py
"$pwsh" -NoProfile -NonInteractive -File transport/test-lan-proxy-config.ps1 < /dev/null
"$dotnet" app/launcher/tests/bin/Debug/lan-tests/net10.0/PortableTests.dll "$repo"
