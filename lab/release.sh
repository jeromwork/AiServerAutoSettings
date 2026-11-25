#!/usr/bin/env bash
# Выпуск версии Лаборатории в GitHub-релиз lab-latest (файлы RemoteAgents-Lab-V<N>.exe копятся для отката).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

[[ $(git rev-parse --abbrev-ref HEAD) == lab ]] || { echo "ОШИБКА: нужна ветка lab" >&2; exit 1; }
[[ -z $(git status --porcelain -- lab ':!lab/out') ]] || { echo "ОШИБКА: в lab/ есть незакоммиченное" >&2; exit 1; }

stage=$(tr -d ' \r\n' < lab/STAGE)
[[ $stage =~ ^V[0-9]+(\.[0-9]+)?$ ]] || { echo "ОШИБКА: lab/STAGE='$stage', нужно V<N>" >&2; exit 1; }
tag="lab-$(echo "$stage" | tr 'V' 'v')"
head=$(git rev-parse HEAD)

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  if [[ $(git rev-parse "refs/tags/$tag^{commit}") != "$head" ]]; then
    echo "ОШИБКА: тег $tag уже указывает на другой коммит; номер не повторять" >&2; exit 1
  fi
fi

if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then git push origin lab; else git push -u origin lab; fi

out=$(timeout 420 flock --close /tmp/heavy-tests.lock bash lab/build.sh | tee /dev/stderr)
ver=$(printf '%s\n' "$out" | sed -n 's/^версия: //p' | tail -1)
[[ $ver == "$stage-"* && $ver != *dirty* ]] || { echo "ОШИБКА: версия сборки '$ver' не подходит" >&2; exit 1; }

exe="lab/out/RemoteAgents-Lab-$stage.exe"
cp lab/out/RemoteAgents-Lab.exe "$exe"
sha=$(sha256sum "$exe" | cut -d' ' -f1)
short=$(git rev-parse --short HEAD)

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag "$tag" HEAD
git push origin "refs/tags/$tag"
git tag -f lab-latest HEAD
git push -f origin refs/tags/lab-latest

if ! gh release view lab-latest >/dev/null 2>&1; then
  gh release create lab-latest --prerelease --title "RemoteAgents Лаборатория" --notes "Лаборатория: тестовые сборки."
fi
gh release upload lab-latest "$exe" lab/out/RemoteAgents-Lab.exe --clobber
notes="Последняя версия: $stage, коммит $short, SHA-256 $sha. Установка: Выход в трее Лаборатории → запустить RemoteAgents-Lab-$stage.exe → UAC Да. Откат: Выход → запустить предыдущий файл RemoteAgents-Lab-V*.exe из этого релиза. Тестовая сборка, автообновления нет."
gh release edit lab-latest --prerelease --notes "$notes"

tmp=$(mktemp -d)
gh release download lab-latest -p "RemoteAgents-Lab-$stage.exe" -D "$tmp"
got=$(sha256sum "$tmp/RemoteAgents-Lab-$stage.exe" | cut -d' ' -f1)
[[ $got == "$sha" ]] || { echo "ОШИБКА: sha256 скачанного $got != $sha" >&2; exit 1; }

echo "https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/download/lab-latest/RemoteAgents-Lab-$stage.exe"
echo "sha256 $sha"
