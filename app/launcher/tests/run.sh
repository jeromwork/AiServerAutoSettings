#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
case ${1:-} in
  '') exec bash "$repo/disk/test-fast.sh" ;;
  --live) exec bash "$repo/disk/test-live.sh" ;;
  --full) shift ;;
  *) echo 'Usage: run.sh [--live|--full]' >&2; exit 2 ;;
esac
# Legacy installer fixtures also use millisecond budgets in the explicit full run.
export REMOTE_DISK_OFFER_TIMEOUT_MS=20 REMOTE_DISK_OFFER_POLL_MS=1 REMOTE_DISK_INSTALL_RETRY_MS=1
# Do not leave compiler/build daemons holding the caller's inherited flock descriptor.
export UseSharedCompilation=false DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER=1 MSBUILDDISABLENODEREUSE=1
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
testdir=$(mktemp -d /tmp/remoteagents-launcher-tests.XXXXXX)
cleanup() {
  if [[ -n ${BARRIER_RETRY_DIR:-} ]]; then
    printf 'BARRIER_RETRY_DIR=%s\n' "$BARRIER_RETRY_DIR"
    printf 'BARRIER_RETRY_TSV=%s/retries.tsv\n' "$BARRIER_RETRY_DIR"
    if [[ -f $BARRIER_RETRY_DIR/retries.tsv ]]; then
      printf 'NAME\tattempt\texit\tseconds\tload1\n'
      cat -- "$BARRIER_RETRY_DIR/retries.tsv"
    fi
  fi
  # CleanupLegacy fixtures deliberately preserve read-only directories. On Linux
  # remove that fixture permission before deleting our own disposable test root.
  chmod -R u+rwX -- "$testdir" 2>/dev/null || true
  if [[ ${BARRIER_RETRY_DIR:-} == "$testdir/retries" ]]; then
    # Keep attempt logs for barrier review, but remove the disposable fixtures.
    find "$testdir" -mindepth 1 -maxdepth 1 ! -name retries -exec rm -rf -- {} +
  else
    rm -rf -- "$testdir"
  fi
}
trap cleanup EXIT
pwsh=${PWSH:-$HOME/.cache/pwsh-test/pwsh}
# BEGIN barrier retry (extracted by test_barrier_retry.py).
BARRIER_RETRIES=${BARRIER_RETRIES:-0}
BARRIER_RETRY_DIR=${BARRIER_RETRY_DIR:-$testdir/retries}
mkdir -p -- "$BARRIER_RETRY_DIR"
flaky() {
  local name=$1 attempt code started load1 deadline remaining
  shift
  for ((attempt=1; attempt<=1+BARRIER_RETRIES; attempt++)); do
    started=$SECONDS
    # A conditional pipeline keeps errexit from aborting before PIPESTATUS is read.
    # The function itself is called directly, so its final failure still stops a group.
    if "$@" 2>&1 | tee "$BARRIER_RETRY_DIR/$name.attempt$attempt.log"; then
      code=${PIPESTATUS[0]}
    else
      code=${PIPESTATUS[0]}
    fi
    read -r load1 _ < /proc/loadavg
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$attempt" "$code" "$((SECONDS-started))" "$load1" >> "$BARRIER_RETRY_DIR/retries.tsv"
    if (( code == 0 )); then return 0; fi
    if (( attempt <= BARRIER_RETRIES )); then
      echo "RETRY[$name] attempt $attempt failed (exit $code), retrying"
      deadline=$((SECONDS+120))
      while (( SECONDS < deadline )); do
        read -r load1 _ < /proc/loadavg
        if LC_ALL=C awk -v l="$load1" 'BEGIN {exit !(l <= 4)}'; then break; fi
        remaining=$((deadline-SECONDS))
        if (( remaining <= 0 )); then break; fi
        if (( remaining > 5 )); then remaining=5; fi
        sleep "$remaining"
      done
    fi
  done
  return "$code"
}
# END barrier retry.
# Optional gate for a shared host; wait before starting each next test/build, not inside its timeout.
wait_for_memory() {
  local minimum=${LAUNCHER_TESTS_MEMORY_MIN_MB:-0} available attempt
  if (( minimum == 0 )); then return 0; fi
  for ((attempt=0; attempt<=20; attempt++)); do
    free -m >&2
    available=$(free -m | awk '/^Mem:/ {print $7}')
    if (( available >= minimum )); then return 0; fi
    if (( attempt == 20 )); then
      echo "SKIP: available memory below ${minimum} MB after 20 waits" >&2
      return 77
    fi
    echo "Memory wait $((attempt+1))/20 (60 seconds)" >&2
    sleep 60
  done
}
# Default to serial groups on the shared host; callers may explicitly opt into overlap.
export LAUNCHER_TESTS_SERIAL=${LAUNCHER_TESTS_SERIAL:-1}
# This suite launches two child suites; the full run allows a 90 s aggregate budget.
# Keep it out of the server/offline overlap: scheduling contention alone can
# double its elapsed time without any failed lifecycle/startup assertions.
wait_for_memory
DISK_TEST_BUDGET_S=90 timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$repo/disk/test-install.ps1" < /dev/null
wait_for_memory
# These groups touch disjoint temporary HOME/state. Keep .NET builds after the
# server group (it builds the same projects); independent offline checks overlap
# SSH wait times. Every child is bounded; the outer caller may set a total limit.
(
  wait_for_memory
  timeout 60 python3 "$here/test_run_modes.py"
  wait_for_memory
  timeout 60 python3 "$here/test_barrier_retry.py"
  wait_for_memory
  timeout 60 python3 "$here/test-config-sync.py"
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-first-install.ps1" -TestHome "$testdir/wizard" < /dev/null
  wait_for_memory
  timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$repo/disk/test-accept.ps1" -TestHome "$testdir/disk-accept" < /dev/null
  wait_for_memory
  timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$repo/disk/test-accept-install.ps1" -TestHome "$testdir/disk-accept-install" < /dev/null
  wait_for_memory
  timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$repo/disk/test-cleanup.ps1" -TestHome "$testdir/disk-cleanup" < /dev/null
  wait_for_memory
  timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$repo/disk/test-pairing.ps1" -TestHome "$testdir/disk-pairing" < /dev/null
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-account.ps1" -TestHome "$testdir/accounts" < /dev/null
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-wizard.ps1" -TestHome "$testdir/setup-wizard" < /dev/null
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-wizard-onboarding.ps1" -TestHome "$testdir/onboarding" < /dev/null
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-wizard-account.ps1" -TestHome "$testdir/wizard-account" < /dev/null
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-navpane.ps1" -TestHome "$testdir/navpane" < /dev/null
  wait_for_memory
  timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-server-apply.ps1" -TestHome "$testdir/server-apply" < /dev/null
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-network.ps1" -TestHome "$testdir/network" < /dev/null
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-config-account.ps1" -TestHome "$testdir/config-account" < /dev/null
  wait_for_memory
  flaky config-bootstrap env LOCALAPPDATA="$testdir/local" timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-config-bootstrap.ps1" -TestHome "$testdir/config-bootstrap" < /dev/null
  wait_for_memory
  timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-ssh-resolve.ps1" -TestHome "$testdir/ssh-resolve" < /dev/null
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$repo/transport/test-transport-config.ps1" < /dev/null
  wait_for_memory
  timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-vpn-legacy.ps1" -TestHome "$testdir/vpn-legacy" < /dev/null
  wait_for_memory
  wait_for_memory
  wait_for_memory
  timeout 60 python3 "$repo/transport/test-vpn-lifecycle.py"
  wait_for_memory
  wait_for_memory
  wait_for_memory
  timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$repo/transport/test-transport-json.ps1" < /dev/null
  wait_for_memory
  timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$repo/transport/test-transport-ports.ps1" < /dev/null
  wait_for_memory
  wait_for_memory
  timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$repo/tools/legacy-cleanup/tests/smoke-plan.ps1" < /dev/null
  wait_for_memory
  timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$repo/transport/test-transport-decide.ps1" < /dev/null
  wait_for_memory
  timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$repo/transport/test-transport-leak.ps1" < /dev/null
  wait_for_memory
  flaky transport-events timeout 120 python3 "$repo/transport/test-transport-events.py" "$pwsh"
  wait_for_memory
  flaky transport-liveness timeout 120 python3 "$repo/transport/test-transport-liveness.py" "$pwsh"
  wait_for_memory
  flaky transport-daemon env TRANSPORT_DAEMON_TEST_BUDGET=400 timeout 420 python3 "$repo/transport/test-transport-daemon.py" "$pwsh"
  wait_for_memory
  timeout 120 python3 "$here/test_first_run.py"
  wait_for_memory
  timeout 60 python3 "$here/test_happier_account_ui.py"
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-config-routes.ps1" -TestHome "$testdir/config-routes" < /dev/null
  wait_for_memory
  timeout 60 bash "$repo/disk/test-live.sh"
  wait_for_memory
  timeout 120 python3 "$repo/disk/test-wizard-merge.py"
  wait_for_memory
  timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-disk-errors.ps1"
  wait_for_memory
  flaky engine-loopback timeout 120 python3 "$repo/transport/test-engine-loopback.py" --without-disk
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-config-engine.ps1" -TestHome "$testdir/config-engine" < /dev/null
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-config-device.ps1" -TestHome "$testdir/config-device" < /dev/null
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-config-scheduler.ps1" -TestHome "$testdir/config-scheduler" < /dev/null
  wait_for_memory
  LOCALAPPDATA="$testdir/local" timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-refresh.ps1" -TestHome "$testdir/config-refresh" < /dev/null
  wait_for_memory
  timeout 120 python3 "$here/test-server-health.py"
  wait_for_memory
  timeout 120 python3 "$repo/transport/test-config-sync-preflight.py"
  wait_for_memory
  timeout 120 python3 "$repo/transport/test-server-catalog.py"
  wait_for_memory
  flaky accounts timeout 120 node "$repo/accounts/test-accounts.mjs"
  wait_for_memory
  timeout 120 python3 "$here/test_build.py"
  wait_for_memory
  timeout 120 python3 "$here/test_update_release.py"
  wait_for_memory
  timeout 60 python3 "$here/test_app_icon.py"
  wait_for_memory
  timeout 120 python3 "$here/test_state_icons.py"
  wait_for_memory
  timeout 60 "$pwsh" -NoProfile -NonInteractive -File "$here/test-control-supervision.ps1" -TestHome "$testdir/control" < /dev/null
  wait_for_memory
  timeout 120 python3 "$here/test_bridge_health.py"
  wait_for_memory
  timeout 120 python3 "$here/test_wizard_boundary.py"
  wait_for_memory
  timeout 120 python3 "$here/test_server_operations.py"
) > "$testdir/offline.log" 2>&1 &
offline_pid=$!
# Opt-in for small shared hosts: retain each group's errexit behavior, but do not overlap them.
failed=0
server_pid=''
trap 'kill "$offline_pid" ${server_pid:+"$server_pid"} 2>/dev/null || true; cleanup' EXIT
if [[ ${LAUNCHER_TESTS_SERIAL:-0} == 1 ]]; then
  wait "$offline_pid" || failed=1
fi
(
  wait_for_memory
  flaky server bash "$repo/server/tests/run.sh"
) > "$testdir/server.log" 2>&1 &
server_pid=$!
if [[ ${LAUNCHER_TESTS_SERIAL:-0} != 1 ]]; then
  wait "$offline_pid" || failed=1
fi
cat "$testdir/offline.log"
wait "$server_pid" || failed=1
cat "$testdir/server.log"
[[ $failed == 0 ]] || exit 1
trap cleanup EXIT
wait_for_memory
timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -- "$testdir/core"
wait_for_memory
# Disk integration is covered by the bounded test-live.sh above.
# Extended engine fixtures remain available for focused diagnostics.
# Config format, enc1, vault and materialization (stream A entry point; own output directory).
wait_for_memory
# LAN entry point also runs NetHelperVersionTests: service/protocol fingerprint and HelperVersion gate.
timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:LanTests=true -- "$repo"
wait_for_memory
# Журналы: формат, маскирование, ротация, конфликты, лестница, журнал помощника; PowerShell-копия формата.
timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -- --logging
timeout 120 "$pwsh" -NoProfile -NonInteractive -File "$here/test-ralog.ps1" "$repo" < /dev/null
wait_for_memory
timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:ConfigTests=true
wait_for_memory
timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:HelperUpdateTests=true
timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:UpdateButtonTests=true
timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:EventBusTests=true
timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:BusJournalTests=true
timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:NetNotifyTests=true
timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:TrayBusTests=true
timeout 120 "$dotnet" run --project "$here/PortableTests.csproj" -c Release -p:SupervisorStaleTests=true
wait_for_memory
# End-to-end on a loopback stand: config export -> paste/vault -> orchestrator -> real Server/Connection -> sync -> revoke.
wait_for_memory
timeout 300 python3 "$here/test_config_e2e.py"
wait_for_memory
if [[ ${SKIP_LAUNCHER_EXE:-0} == 1 ]]; then
  timeout 120 "$repo/build/make-bundle.sh" 20261109.235959-test "$testdir/bundles"
  echo 'SKIP: Windows launcher EXE build/publish (SKIP_LAUNCHER_EXE=1)'
  exit 0
fi
# Same pinned cache as build-exe.sh, but tests must never fetch from the network.
timeout 120 python3 - "$repo" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, str(Path(sys.argv[1])/'build'))
import bundle
if any(not bundle.archive_path(row).is_file() for row in bundle.pinned()):
    sys.exit('FAIL: нет кэша pinned binaries: запустите python3 build/bundle.py fetch')
PY
timeout 120 "$repo/build/make-bundle.sh" 20261109.235959-test "$testdir/bundles" --binaries
timeout 120 python3 "$repo/build/bundle.py" verify-initial "$testdir/bundles/20261109.235959-test.zip"
wait_for_memory
timeout 120 "$dotnet" build "$repo/app/launcher/RemoteAgents.Launcher.csproj" -c Release -p:BundlePath="$testdir/bundles/20261109.235959-test.zip" --nologo
wait_for_memory
timeout 120 "$dotnet" publish "$repo/app/launcher/RemoteAgents.Launcher.csproj" -c Release -p:BundlePath="$testdir/bundles/20261109.235959-test.zip" -o "$testdir/publish" --nologo
wait_for_memory
timeout 120 python3 - "$testdir/publish" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
assert (p/'RemoteAgents.exe').read_bytes()[:2] == b'MZ'
assert not list(p.glob('*.dll')), 'Unexpected runtime dependencies'
print('PASS: net48 build/publish; PE EXE exists; no DLL dependencies')
PY
# The published EXE must carry app.ico as its application icon (it had none: Explorer showed the stock window icon).
wait_for_memory
timeout 60 python3 "$here/test_app_icon.py" "$testdir/publish/RemoteAgents.exe"
# ... and carry the folder state icons as resources, byte for byte.
wait_for_memory
timeout 60 python3 "$here/test_state_icons.py" "$testdir/publish/RemoteAgents.exe"
