#!/usr/bin/env bash
# Собирает EXE лаборатории и кладёт его на рабочий стол ПК в RemoteAgents-Lab-версии под именем с версией:
# каждая сборка остаётся файлом рядом с прежними, откат = запустить предыдущий.
# Запуск (ПК подключён): timeout 420 flock --close /tmp/heavy-tests.lock bash lab/deliver.sh
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)   # lab/
out=${LAB_OUT:-$here/out}
log=$(mktemp)
trap 'rm -f "$log"' EXIT
bash "$here/build.sh" | tee "$log"
version=$(sed -n 's/^версия: //p' "$log" | tail -n1)
if [[ -z $version ]]; then echo "ОШИБКА: build.sh не вывел версию" >&2; exit 1; fi
dest='C:\Users\user\Desktop\RemoteAgents-Lab-версии'
ra-lab write "$dest\\RemoteAgents-Lab-$version.exe" "$out/RemoteAgents-Lab.exe"
echo "Положено на ПК: $dest\\RemoteAgents-Lab-$version.exe"
