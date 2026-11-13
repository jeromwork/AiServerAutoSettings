#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
testdir=$(mktemp -d /tmp/remoteagents-launcher-tests.XXXXXX)
trap 'rm -rf "$testdir"' EXIT
pwsh=${PWSH:-$HOME/.cache/pwsh-test/pwsh}
check() { if "$@"; then :; else rc=$?; echo "FAIL ($rc): $*"; group_failed=1; fi; }
# These groups touch disjoint temporary HOME/state. Keep .NET builds after the
# server group (it builds the same projects); independent offline checks overlap
# SSH wait times. Every child is bounded; the outer caller may set a total limit.
(
  group_failed=0
  check timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-cloud.ps1"
  LOCALAPPDATA="$testdir/local" check timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-first-install.ps1" -TestHome "$testdir/wizard" < /dev/null
  LOCALAPPDATA="$testdir/local" check timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-account.ps1" -TestHome "$testdir/accounts" < /dev/null
  LOCALAPPDATA="$testdir/local" check timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-wizard.ps1" -TestHome "$testdir/setup-wizard" < /dev/null
  LOCALAPPDATA="$testdir/local" check timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-wizard-onboarding.ps1" -TestHome "$testdir/onboarding" < /dev/null
  LOCALAPPDATA="$testdir/local" check timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-wizard-account.ps1" -TestHome "$testdir/wizard-account" < /dev/null
  LOCALAPPDATA="$testdir/local" check timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-network.ps1" -TestHome "$testdir/network" < /dev/null
  LOCALAPPDATA="$testdir/local" check timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-config-account.ps1" -TestHome "$testdir/config-account" < /dev/null
  LOCALAPPDATA="$testdir/local" check timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-config-bootstrap.ps1" -TestHome "$testdir/config-bootstrap" < /dev/null
  LOCALAPPDATA="$testdir/local" check timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$repo/transport/test-transport-config.ps1" < /dev/null
  check timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$repo/transport/test-transport-json.ps1" < /dev/null
  check timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$repo/transport/test-transport-ports.ps1" < /dev/null
  check timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$repo/tools/legacy-cleanup/tests/smoke-plan.ps1" < /dev/null
  check timeout 120 python3 "$repo/transport/test-transport-liveness.py" "$pwsh"
  check timeout 180 python3 "$repo/transport/test-transport-daemon.py" "$pwsh"
  check timeout 120 python3 "$here/test_first_run.py"
  check timeout 60 python3 "$here/test_happier_account_ui.py"
  LOCALAPPDATA="$testdir/local" check timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-config-routes.ps1" -TestHome "$testdir/config-routes" < /dev/null
  check timeout 120 python3 "$repo/transport/test-engine-loopback.py" --without-disk
  LOCALAPPDATA="$testdir/local" check timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-config-engine.ps1" -TestHome "$testdir/config-engine" < /dev/null
  LOCALAPPDATA="$testdir/local" check timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-config-device.ps1" -TestHome "$testdir/config-device" < /dev/null
  LOCALAPPDATA="$testdir/local" check timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-config-scheduler.ps1" -TestHome "$testdir/config-scheduler" < /dev/null
  LOCALAPPDATA="$testdir/local" check timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-refresh.ps1" -TestHome "$testdir/config-refresh" < /dev/null
  check timeout 60 python3 "$here/test-config-sync.py"
  check timeout 60 python3 "$here/test-server-health.py"
  check timeout 120 python3 "$repo/transport/test-config-sync-preflight.py"
  check timeout 120 python3 "$repo/transport/test-server-catalog.py"
  check timeout 120 node "$repo/accounts/test-accounts.mjs"
  check timeout 120 python3 "$here/test_build.py"
  check timeout 120 python3 "$here/test_bridge_health.py"
  check timeout 120 python3 "$here/test_wizard_boundary.py"
  check timeout 120 python3 "$here/test_server_operations.py"
  exit "$group_failed"
) > "$testdir/offline.log" 2>&1 &
offline_pid=$!
(
  bash "$repo/server/tests/run.sh"
) > "$testdir/server.log" 2>&1 &
server_pid=$!
trap 'kill "$offline_pid" "$server_pid" 2>/dev/null || true; rm -rf "$testdir"' EXIT
failed=0
wait "$offline_pid" || failed=1
cat "$testdir/offline.log"
wait "$server_pid" || failed=1
cat "$testdir/server.log"
group_failed=0
trap 'rm -rf "$testdir"' EXIT
check timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -- "$testdir/core"
check timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:ProductName=RemoteVPN -- "$testdir/core-vpn"
# Config format, enc1, vault and materialization (stream A entry point; own output directory).
check timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:ConfigTests=true
check timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:ConfigTests=true -p:ProductName=RemoteVPN
# End-to-end on a loopback stand: config export -> paste/vault -> orchestrator -> real Server/Connection -> sync -> revoke.
check timeout 120 python3 "$here/test_config_e2e.py"
check timeout 120 "$repo/build/make-bundle.sh" 20261109.235959-test "$testdir/bundles"
if [[ ${SKIP_LAUNCHER_EXE:-0} == 1 ]]; then
  echo 'SKIP: Windows launcher EXE build/publish (SKIP_LAUNCHER_EXE=1)'
  [[ $group_failed == 0 ]] || failed=1
  exit "$failed"
fi
check timeout 120 "$dotnet" build "$repo/app/launcher/RemoteAgents.Launcher.csproj" -c Release -p:BundlePath="$testdir/bundles/20261109.235959-test.zip" --nologo
check timeout 120 "$dotnet" publish "$repo/app/launcher/RemoteAgents.Launcher.csproj" -c Release -p:BundlePath="$testdir/bundles/20261109.235959-test.zip" -o "$testdir/publish" --nologo
check timeout 120 python3 - "$testdir/publish" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
assert (p/'RemoteAgents.exe').read_bytes()[:2] == b'MZ'
assert not list(p.glob('*.dll')), 'Unexpected runtime dependencies'
print('PASS: net48 build/publish; PE EXE exists; no DLL dependencies')
PY

[[ $group_failed == 0 ]] || failed=1
exit "$failed"
