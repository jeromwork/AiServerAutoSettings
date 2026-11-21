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

# Accept exactly alias [dist] [--prepared directory]; reject trailing/unknown arguments.
remaining=("${args[@]:1}")
if [[ ${#remaining[@]} -gt 0 && "${remaining[0]}" != "--prepared" ]]; then
  [[ "${remaining[0]}" != -* ]] || exit 2
  dist="${remaining[0]}"
  remaining=("${remaining[@]:1}")
fi
if [[ ${#remaining[@]} -gt 0 ]]; then
  [[ ${#remaining[@]} -eq 2 && "${remaining[0]}" == "--prepared" && -n "${remaining[1]}" && "${remaining[1]}" != -* ]] || { echo "Ожидается --prepared папка-сборки без лишних аргументов" >&2; exit 2; }
  prepared="${remaining[1]}"
fi

check_channel_isolation "$RELEASE_CHANNEL" "$dist" || exit 1

"$here/require-main.sh" --channel "$RELEASE_CHANNEL"
if [[ -n "$prepared" ]]; then
  out="$prepared"
  check_build_channel "$RELEASE_CHANNEL" "$out" || exit 1
  git -C "$repo" diff --quiet -- . ':!release' || { echo "Исходники $RELEASE_CHANNEL изменены" >&2; exit 1; }
else
  [[ -z $(git -C "$repo" status --porcelain) ]] || { echo "Перед сборкой нужен чистый $RELEASE_CHANNEL" >&2; exit 1; }
  "$here/build-exe.sh" --channel "$RELEASE_CHANNEL"
  default_out="$here/out"
  [[ "$RELEASE_CHANNEL" != "test" ]] || default_out="$here/out-test"
  out=${REMOTEAGENTS_BUILD_OUT:-$default_out}
  check_build_channel "$RELEASE_CHANNEL" "$out" || exit 1
fi
stage=$(mktemp -d); trap 'rm -rf -- "$stage"' EXIT
python3 "$here/bundle.py" publish "$out/bundle.zip" "$stage/agents" --launcher "$out/$RELEASE_EXE" --product "$RELEASE_PRODUCT" --channel "$RELEASE_CHANNEL"
python3 "$here/release-dist.py" metadata "$stage" "$stage/release-info.json" "$(git -C "$repo" rev-parse HEAD)" --product "$RELEASE_PRODUCT" --channel "$RELEASE_CHANNEL"
if [[ -n "$prepared" ]]; then
  cmp -- "$stage/release-info.json" "$out/release-info.json" || { echo "Подготовленная сборка не совпадает с HEAD или файлами" >&2; exit 1; }
else
  cp -- "$stage/release-info.json" "$out/release-info.json"
fi
"$here/release-github.sh" --channel "$RELEASE_CHANNEL" "$out"
# tar stdin contains only local staged payloads; no command/config/credentials cross the shell unquoted.
remote_command=$(python3 "$here/release-dist.py" command "$dist" --product "$RELEASE_PRODUCT" --channel "$RELEASE_CHANNEL")
tar -C "$stage" -cf - agents | ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -- "$server" "$remote_command"
echo "Оба источника проверены по SHA-256; версия и EXE совпадают ($RELEASE_CHANNEL)."
