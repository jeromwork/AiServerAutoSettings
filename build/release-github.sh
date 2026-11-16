#!/usr/bin/env bash
# Одна программа — один релиз (конституция 7а): EXE из main заменяют файлы в релизе main-latest,
# тег main-latest переезжает на собранный коммит. Новых релизов на каждую сборку не заводим.
# Использование: build/release-github.sh <папка сборки с RemoteAgents.exe и RemoteVPN.exe> [коммит]
set -euo pipefail
dir=${1:?папка сборки}; commit=${2:-$(git rev-parse HEAD)}; tag=main-latest
[[ $(git branch -r --contains "$commit" | grep -c 'origin/main$') -ge 1 ]] || { echo "Коммит $commit не в origin/main — выкладываем только main" >&2; exit 1; }
sums=$(cd "$dir" && sha256sum RemoteAgents.exe RemoteVPN.exe)
notes="Последняя сборка RemoteAgents из main ($(git rev-parse --short "$commit"), $(date -u +%d.%m.%Y)). Ссылка на файл постоянная.

SHA-256:
$sums"
git tag -f "$tag" "$commit" >/dev/null && git push -q -f origin "refs/tags/$tag"
if gh release view "$tag" >/dev/null 2>&1; then
  gh release edit "$tag" --prerelease --title "RemoteAgents — последняя сборка" --notes "$notes" >/dev/null
  gh release upload "$tag" "$dir/RemoteAgents.exe" "$dir/RemoteVPN.exe" --clobber
else
  gh release create "$tag" "$dir/RemoteAgents.exe" "$dir/RemoteVPN.exe" --prerelease --title "RemoteAgents — последняя сборка" --notes "$notes" >/dev/null
fi
tmp=$(mktemp -d); gh release download "$tag" -p RemoteAgents.exe -D "$tmp"
[[ $(sha256sum "$tmp/RemoteAgents.exe" | cut -d' ' -f1) == $(sha256sum "$dir/RemoteAgents.exe" | cut -d' ' -f1) ]] || { echo 'Хеш скачанного не совпал' >&2; exit 1; }
rm -rf "$tmp"
echo "https://github.com/jeromwork/AiServerAutoSettings/releases/download/$tag/RemoteAgents.exe"
echo "$sums"
