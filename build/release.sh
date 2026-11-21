#!/usr/bin/env bash
# Build once from main (or int/vpn-master for test), publish the exact same EXEs to <tag> and the owner's SSH dist.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
source "$here/release-lib.sh"

channel="main"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      [[ $# -ge 2 ]] || { echo "Требуется имя канала после --channel" >&2; exit 2; }
      channel="$2"
      shift 2
      ;;
    --channel=*)
      channel="${1#*=}"
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

resolve_channel "$channel" || exit 1

[[ ${#args[@]} -ge 1 ]] || { echo "Использование: build/release.sh [--channel main|test] SSH-алиас [remote-dist] [--prepared папка-сборки]" >&2; exit 2; }
server="${args[0]}"
[[ $server != -* && $server != *$'\n'* && $server != *$'\r'* ]] || exit 2

dist="${RELEASE_DIST_DEFAULT}"
prepared=""
out=""

if [[ ${#args[@]} -ge 2 ]]; then
  if [[ "${args[1]}" == "--prepared" ]]; then
    prepared="${args[2]:?Требуется папка сборки после --prepared}"
  else
    dist="${args[1]}"
    if [[ ${#args[@]} -ge 3 && "${args[2]}" == "--prepared" ]]; then
      prepared="${args[3]:?Требуется папка сборки после --prepared}"
    fi
  fi
fi

check_channel_isolation "$RELEASE_CHANNEL" "$dist" || exit 1

"$here/require-main.sh" --channel "$RELEASE_CHANNEL"
if [[ -n "$prepared" ]]; then
  out="$prepared"
  git -C "$repo" diff --quiet -- . ':!release' || { echo "Исходники $RELEASE_CHANNEL изменены" >&2; exit 1; }
else
  [[ -z $(git -C "$repo" status --porcelain) ]] || { echo "Перед сборкой нужен чистый $RELEASE_CHANNEL" >&2; exit 1; }
  "$here/build-exe.sh" --channel "$RELEASE_CHANNEL"
  out=${REMOTEAGENTS_BUILD_OUT:-$here/out}
fi
stage=$(mktemp -d); trap 'rm -rf -- "$stage"' EXIT
python3 "$here/bundle.py" publish "$out/bundle.zip" "$stage/agents" --launcher "$out/$RELEASE_EXE"
python3 "$here/release-dist.py" metadata "$stage" "$stage/release-info.json" "$(git -C "$repo" rev-parse HEAD)"
if [[ -n "$prepared" ]]; then
  cmp -- "$stage/release-info.json" "$out/release-info.json" || { echo "Подготовленная сборка не совпадает с HEAD или файлами" >&2; exit 1; }
else
  cp -- "$stage/release-info.json" "$out/release-info.json"
fi
"$here/release-github.sh" --channel "$RELEASE_CHANNEL" "$out"
# tar stdin contains only local staged payloads; no command/config/credentials cross the shell unquoted.
remote_command=$(python3 "$here/release-dist.py" command "$dist")
tar -C "$stage" -cf - agents | ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -- "$server" "$remote_command"
echo "Оба источника проверены по SHA-256; версия и EXE совпадают ($RELEASE_CHANNEL)."
