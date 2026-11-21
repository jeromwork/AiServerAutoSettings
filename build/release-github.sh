#!/usr/bin/env bash
# Одна программа — один релиз (конституция 7а): EXE заменяют файлы в релизе main-latest (или test-latest),
# тег переезжает на собранный коммит. Новых релизов на каждую сборку не заводим.
# Использование: build/release-github.sh [--channel main|test] <папка сборки с EXE> [коммит]
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

[[ ${#args[@]} -ge 1 ]] || { echo "Использование: build/release-github.sh [--channel main|test] <папка сборки> [коммит]" >&2; exit 2; }
dir=$(cd -- "${args[0]}" && pwd)
cd -- "$repo"

commit=${args[1]:-$(git rev-parse HEAD)}
tag="$RELEASE_TAG"
exe_name="$RELEASE_EXE"

"$here/require-main.sh" --channel "$RELEASE_CHANNEL" "$commit"
[[ -f "$dir/release-info.json" ]] || { echo "Нужна общая сборка: build/release.sh --channel $RELEASE_CHANNEL" >&2; exit 1; }
python3 "$here/release-dist.py" verify "$dir" "$commit" || true
sums=$(cd "$dir" && sha256sum "$exe_name")

if [[ "$RELEASE_CHANNEL" == "test" ]]; then
  title="RemoteAgentsTest — тестовая сборка"
  notes="Тестовая сборка RemoteAgentsTest из int/vpn-master ($(git rev-parse --short "$commit"), $(date -u +%d.%m.%Y)). Ссылка на файл постоянная.

SHA-256:
$sums"
else
  title="RemoteAgents — последняя сборка"
  notes="Последняя сборка RemoteAgents из main ($(git rev-parse --short "$commit"), $(date -u +%d.%m.%Y)). Ссылка на файл постоянная.

SHA-256:
$sums"
fi

git tag -f "$tag" "$commit" >/dev/null && git push -q -f origin "refs/tags/$tag"
if gh release view "$tag" >/dev/null 2>&1; then
  gh release edit "$tag" --prerelease --title "$title" --notes "$notes" >/dev/null
  gh release upload "$tag" "$dir/$exe_name" "$dir/release-info.json" --clobber
else
  gh release create "$tag" "$dir/$exe_name" "$dir/release-info.json" --prerelease --title "$title" --notes "$notes" >/dev/null
fi
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
gh release download "$tag" -p "$exe_name" -p release-info.json -D "$tmp"
for name in "$exe_name" release-info.json; do
  [[ $(sha256sum "$tmp/$name" | cut -d' ' -f1) == $(sha256sum "$dir/$name" | cut -d' ' -f1) ]] || { echo "Хеш $name не совпал" >&2; exit 1; }
done
echo "https://github.com/jeromwork/AiServerAutoSettings/releases/download/$tag/$exe_name"
echo "$sums"
