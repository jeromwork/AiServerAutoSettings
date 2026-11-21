#!/usr/bin/env bash
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
      channel="$2"; shift 2 ;;
    --channel=*)
      channel="${1#*=}"; shift ;;
    *)
      args+=("$1"); shift ;;
  esac
done

resolve_channel "$channel" || exit 1

commit=""
if [[ ${#args[@]} -gt 0 ]]; then
  commit="${args[0]}"
else
  commit=$(git -C "$repo" rev-parse HEAD)
fi

require_channel_commit "$channel" "$commit" "$repo"
