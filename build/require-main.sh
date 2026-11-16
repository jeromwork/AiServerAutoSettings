#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $(git -C "$repo" branch --show-current) == main ]] || { echo 'Выкладка разрешена только из main' >&2; exit 1; }
commit=${1:-$(git -C "$repo" rev-parse HEAD)}
[[ $(git -C "$repo" rev-parse "$commit") == $(git -C "$repo" rev-parse HEAD) ]] || { echo 'Коммит не совпадает с main HEAD' >&2; exit 1; }
git -C "$repo" merge-base --is-ancestor "$commit" origin/main || { echo 'Коммит ещё не в origin/main' >&2; exit 1; }
