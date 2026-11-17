#!/usr/bin/env bash
# Одна программа — один релиз (конституция 7а): EXE из main заменяют файлы в релизе main-latest,
# тег main-latest переезжает на собранный коммит. Новых релизов на каждую сборку не заводим.
# Использование: build/release-github.sh <папка сборки с RemoteAgents.exe> [коммит]
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
dir=$(cd -- "${1:?папка сборки}" && pwd)
cd -- "$repo"
commit=${2:-$(git rev-parse HEAD)}; tag=main-latest
"$here/require-main.sh" "$commit"
[[ -f "$dir/release-info.json" ]] || { echo 'Нужна общая сборка: build/release.sh' >&2; exit 1; }
python3 "$here/release-dist.py" verify "$dir" "$commit"
sums=$(cd "$dir" && sha256sum RemoteAgents.exe)
notes="Последняя сборка RemoteAgents из main ($(git rev-parse --short "$commit"), $(date -u +%d.%m.%Y)). Ссылка на файл постоянная.

SHA-256:
$sums"
git tag -f "$tag" "$commit" >/dev/null && git push -q -f origin "refs/tags/$tag"
if gh release view "$tag" >/dev/null 2>&1; then
  gh release edit "$tag" --prerelease --title "RemoteAgents — последняя сборка" --notes "$notes" >/dev/null
  gh release upload "$tag" "$dir/RemoteAgents.exe" "$dir/release-info.json" --clobber
else
  gh release create "$tag" "$dir/RemoteAgents.exe" "$dir/release-info.json" --prerelease --title "RemoteAgents — последняя сборка" --notes "$notes" >/dev/null
fi
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
gh release download "$tag" -p RemoteAgents.exe -p release-info.json -D "$tmp"
for name in RemoteAgents.exe release-info.json; do
  [[ $(sha256sum "$tmp/$name" | cut -d' ' -f1) == $(sha256sum "$dir/$name" | cut -d' ' -f1) ]] || { echo "Хеш $name не совпал" >&2; exit 1; }
done
echo "https://github.com/jeromwork/AiServerAutoSettings/releases/download/$tag/RemoteAgents.exe"
echo "$sums"
