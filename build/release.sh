#!/usr/bin/env bash
# Build once from main, publish the exact same EXEs to main-latest and the owner's SSH dist.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
server=${1:?Использование: build/release.sh SSH-алиас [remote-dist] [--prepared папка-сборки]}
dist=${2:-~/.local/share/remote-agents/dist}
# Literal ~ is expanded by the remote Python process, not by this machine.
[[ $# -ge 2 ]] || dist='~/.local/share/remote-agents/dist'
[[ $server != -* && $server != *$'\n'* && $server != *$'\r'* ]] || exit 2
"$here/require-main.sh"
if [[ ${3:-} == --prepared && $# == 4 ]]; then
  out=$4
  git -C "$repo" diff --quiet -- . ':!release' || { echo 'Исходники main изменены' >&2; exit 1; }
else
  [[ $# -le 2 ]] || exit 2
  [[ -z $(git -C "$repo" status --porcelain) ]] || { echo 'Перед сборкой нужен чистый main' >&2; exit 1; }
  "$here/build-exe.sh"
  out=${REMOTEAGENTS_BUILD_OUT:-$here/out}
fi
stage=$(mktemp -d); trap 'rm -rf -- "$stage"' EXIT
python3 "$here/bundle.py" publish "$out/bundle.zip" "$stage/agents" --launcher "$out/RemoteAgents.exe"
python3 "$here/bundle.py" publish "$out/vpn-bundle.zip" "$stage/vpn" --launcher "$out/RemoteVPN.exe"
python3 "$here/release-dist.py" metadata "$stage" "$stage/release-info.json" "$(git -C "$repo" rev-parse HEAD)"
if [[ ${3:-} == --prepared ]]; then
  cmp -- "$stage/release-info.json" "$out/release-info.json" || { echo 'Подготовленная сборка не совпадает с main HEAD или файлами' >&2; exit 1; }
else
  cp -- "$stage/release-info.json" "$out/release-info.json"
fi
"$here/release-github.sh" "$out"
# tar stdin contains only local staged payloads; no command/config/credentials cross the shell unquoted.
remote_command=$(python3 "$here/release-dist.py" command "$dist")
tar -C "$stage" -cf - agents vpn | ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -- "$server" "$remote_command"
echo 'Оба источника проверены по SHA-256; версия и EXE совпадают.'
