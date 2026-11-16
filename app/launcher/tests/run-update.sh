#!/usr/bin/env bash
# Focused final check; caller owns /tmp/heavy-tests.lock and the aggregate 420-second timeout.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
work=$(mktemp -d /tmp/remoteagents-update-tests.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
cd -- "$repo"
for product in RemoteAgents RemoteVPN; do
  timeout 420 "$dotnet" run --project "$here/PortableTests.csproj" -c Release --no-restore -p:UseSharedCompilation=false -p:UpdateTests=true -p:ProductName="$product" -- "$work/$product"
done
timeout 420 "$dotnet" run --project "$here/PortableTests.csproj" -c Release --no-restore -p:UseSharedCompilation=false -p:ConfigTests=true
timeout 420 python3 "$here/test_update_release.py"
timeout 420 python3 "$here/test_first_run.py"
PYTHONPATH="$repo/server/tests${PYTHONPATH:+:$PYTHONPATH}" timeout 420 python3 -m unittest -v test_config_export.ConfigExportTests.test_program_updates_default_on_and_explicit_override
echo 'PASS: focused update checks'
