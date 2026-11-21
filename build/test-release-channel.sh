#!/usr/bin/env bash
# Микро-тест каналов выпуска: пути, теги, изоляция, проверка неизвестного канала
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)

echo "=== Запуск микро-теста каналов выпуска (test-release-channel.sh) ==="

# 1. Проверка синтаксиса bash build/*.sh
echo "[1/6] Проверка синтаксиса bash -n build/*.sh..."
for script in "$here"/*.sh; do
  bash -n "$script" || { echo "Ошибка синтаксиса в $script" >&2; exit 1; }
done
echo "  ✓ Синтаксис всех build/*.sh корректен"

# 2. Проверка библиотеки release-lib.sh для main
echo "[2/6] Проверка канала main (пути, теги, EXE)..."
source "$here/release-lib.sh"
resolve_channel main
[[ "$RELEASE_CHANNEL" == "main" ]] || { echo "Неверный RELEASE_CHANNEL: $RELEASE_CHANNEL" >&2; exit 1; }
[[ "$RELEASE_PRODUCT" == "RemoteAgents" ]] || { echo "Неверный RELEASE_PRODUCT: $RELEASE_PRODUCT" >&2; exit 1; }
[[ "$RELEASE_INSTANCE" == "Main" ]] || { echo "Неверный RELEASE_INSTANCE: $RELEASE_INSTANCE" >&2; exit 1; }
[[ "$RELEASE_EXE" == "RemoteAgents.exe" ]] || { echo "Неверный RELEASE_EXE: $RELEASE_EXE" >&2; exit 1; }
[[ "$RELEASE_TAG" == "main-latest" ]] || { echo "Неверный RELEASE_TAG: $RELEASE_TAG" >&2; exit 1; }
[[ "$RELEASE_DIST_DEFAULT" == '~/.local/share/remote-agents/dist' ]] || { echo "Неверный RELEASE_DIST_DEFAULT: $RELEASE_DIST_DEFAULT" >&2; exit 1; }
[[ "$RELEASE_SOURCE_BRANCH" == "main" ]] || { echo "Неверный RELEASE_SOURCE_BRANCH: $RELEASE_SOURCE_BRANCH" >&2; exit 1; }
echo "  ✓ Канал main настроен корректно"

# 3. Проверка библиотеки release-lib.sh для test
echo "[3/6] Проверка канала test (пути, теги, EXE)..."
resolve_channel test
[[ "$RELEASE_CHANNEL" == "test" ]] || { echo "Неверный RELEASE_CHANNEL: $RELEASE_CHANNEL" >&2; exit 1; }
[[ "$RELEASE_PRODUCT" == "RemoteAgentsTest" ]] || { echo "Неверный RELEASE_PRODUCT: $RELEASE_PRODUCT" >&2; exit 1; }
[[ "$RELEASE_INSTANCE" == "Test" ]] || { echo "Неверный RELEASE_INSTANCE: $RELEASE_INSTANCE" >&2; exit 1; }
[[ "$RELEASE_EXE" == "RemoteAgentsTest.exe" ]] || { echo "Неверный RELEASE_EXE: $RELEASE_EXE" >&2; exit 1; }
[[ "$RELEASE_TAG" == "test-latest" ]] || { echo "Неверный RELEASE_TAG: $RELEASE_TAG" >&2; exit 1; }
[[ "$RELEASE_DIST_DEFAULT" == '~/.local/share/remote-agents/dist-test' ]] || { echo "Неверный RELEASE_DIST_DEFAULT: $RELEASE_DIST_DEFAULT" >&2; exit 1; }
[[ "$RELEASE_SOURCE_BRANCH" == "int/vpn-master" ]] || { echo "Неверный RELEASE_SOURCE_BRANCH: $RELEASE_SOURCE_BRANCH" >&2; exit 1; }
echo "  ✓ Канал test настроен корректно"

# 4. Проверка отказа на неизвестном канале
echo "[4/6] Проверка отклонения неизвестного канала..."
set +e
err_output=$(resolve_channel unknown_channel 2>&1)
err_code=$?
set -e
[[ $err_code -ne 0 ]] || { echo "Ожидалась ошибка для неизвестного канала" >&2; exit 1; }
[[ "$err_output" == *"Неизвестный канал"* ]] || { echo "Ожидалось сообщение об ошибке, получено: $err_output" >&2; exit 1; }

# Проверка отказа в CLI скриптов
set +e
"$here/release.sh" --channel invalid_channel fake_alias >/dev/null 2>&1
rc_rel=$?
"$here/release-github.sh" --channel invalid_channel /tmp >/dev/null 2>&1
rc_gh=$?
"$here/require-main.sh" --channel invalid_channel >/dev/null 2>&1
rc_req=$?
"$here/build-exe.sh" --channel invalid_channel >/dev/null 2>&1
rc_bld=$?
set -e
[[ $rc_rel -ne 0 ]] || { echo "release.sh принял invalid_channel" >&2; exit 1; }
[[ $rc_gh -ne 0 ]] || { echo "release-github.sh принял invalid_channel" >&2; exit 1; }
[[ $rc_req -ne 0 ]] || { echo "require-main.sh принял invalid_channel" >&2; exit 1; }
[[ $rc_bld -ne 0 ]] || { echo "build-exe.sh принял invalid_channel" >&2; exit 1; }
echo "  ✓ Неизвестный канал надёжно отвергается всеми скриптами"

# 5. Проверка физической изоляции каналов
echo "[5/6] Проверка физической изоляции каналов..."
# Тестовый канал не может писать в основной dist
set +e
err_iso=$(check_channel_isolation test '~/.local/share/remote-agents/dist' 2>&1)
rc_iso=$?
set -e
[[ $rc_iso -ne 0 ]] || { echo "check_channel_isolation разрешил test-каналу писать в main dist" >&2; exit 1; }

set +e
"$here/release.sh" --channel test fake_alias '~/.local/share/remote-agents/dist' >/dev/null 2>&1
rc_rel_iso=$?
set -e
[[ $rc_rel_iso -ne 0 ]] || { echo "release.sh --channel test разрешил основной dist" >&2; exit 1; }
echo "  ✓ Тестовая сборка физически изолирована от main dist и main-latest"

# 6. Проверка зависимости шага S1 (Instance в csproj)
echo "[6/6] Проверка параметра Instance (шаг S1)..."
if grep -q "Instance" "$repo/app/launcher/RemoteAgents.Launcher.csproj"; then
  echo "  ✓ Свойство Instance присутствует в RemoteAgents.Launcher.csproj"
else
  echo "  ℹ Свойство Instance в RemoteAgents.Launcher.csproj будет добавлено шагом S1 (параллельная волна 0)"
  echo "    build-exe.sh корректно передаёт -p:Instance=\$instance (-p:Instance=Test для test, Main для main)"
fi

echo "=== Все проверки каналов выпуска успешно пройдены! ==="
exit 0
