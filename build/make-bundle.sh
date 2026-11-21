#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/release-lib.sh"

channel=""
product=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      [[ $# -ge 2 ]] || { echo "Требуется имя канала после --channel" >&2; exit 2; }
      channel="$2"; shift 2 ;;
    --channel=*)
      channel="${1#*=}"; shift ;;
    --product)
      product="$2"; shift 2 ;;
    --product=*)
      product="${1#*=}"; shift ;;
    *)
      args+=("$1"); shift ;;
  esac
done

if [[ -n "$channel" ]]; then
  resolve_channel "$channel" || exit 1
  product="$RELEASE_PRODUCT"
fi

product=${product:-RemoteAgents}
# Forward to bundle.py with supported product flag
exec python3 "$here/bundle.py" make "${args[@]}" --product "$product"
