#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
testdir=$(mktemp -d /tmp/remoteagents-launcher-tests.XXXXXX)
trap 'rm -rf "$testdir"' EXIT
pwsh=${PWSH:-$HOME/.cache/pwsh-test/pwsh}
LOCALAPPDATA="$testdir/local" "$pwsh" -NoProfile -NonInteractive -File "$here/test-migrate.ps1" -TestHome "$testdir/migrate" < /dev/null
LOCALAPPDATA="$testdir/local" "$pwsh" -NoProfile -NonInteractive -File "$here/test-first-install.ps1" -TestHome "$testdir/wizard" < /dev/null
LOCALAPPDATA="$testdir/local" "$pwsh" -NoProfile -NonInteractive -File "$here/test-selective.ps1" -TestHome "$testdir/selective" < /dev/null
LOCALAPPDATA="$testdir/local" "$pwsh" -NoProfile -NonInteractive -File "$here/test-account.ps1" -TestHome "$testdir/accounts" < /dev/null
LOCALAPPDATA="$testdir/local" "$pwsh" -NoProfile -NonInteractive -File "$here/test-wizard.ps1" -TestHome "$testdir/setup-wizard" < /dev/null
LOCALAPPDATA="$testdir/local" "$pwsh" -NoProfile -NonInteractive -File "$here/test-wizard-onboarding.ps1" -TestHome "$testdir/onboarding" < /dev/null
python3 "$repo/disk/test-tree.py"
python3 "$repo/transport/test-server-catalog.py"
node "$repo/accounts/test-accounts.mjs"
python3 "$here/test_build.py"
python3 "$here/test_bridge_health.py"
python3 "$here/test_wizard_boundary.py"
"$dotnet" run --project "$here/PortableTests.csproj" -c Release -- "$testdir/core"
"$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:ProductName=RemoteVPN -- "$testdir/core-vpn"
"$repo/build/make-bundle.sh" 20261109.235959-test "$testdir/bundles"
"$dotnet" build "$repo/app/launcher/RemoteAgents.Launcher.csproj" -c Release -p:BundlePath="$testdir/bundles/20261109.235959-test.zip" --nologo
"$dotnet" publish "$repo/app/launcher/RemoteAgents.Launcher.csproj" -c Release -p:BundlePath="$testdir/bundles/20261109.235959-test.zip" -o "$testdir/publish" --nologo
python3 - "$testdir/publish" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
assert (p/'RemoteAgents.exe').read_bytes()[:2] == b'MZ'
assert not list(p.glob('*.dll')), 'Unexpected runtime dependencies'
print('PASS: net48 build/publish; PE EXE exists; no DLL dependencies')
PY
