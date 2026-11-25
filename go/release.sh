#!/usr/bin/env bash
# release.sh — выпуск релиза v3 в GitHub Releases (тег v3-latest).
# Образец: lab/release.sh
# Запуск только координатором из ветки main.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || (cd "$HERE/.." && pwd))
DIST_DIR="$HERE/dist"

TAG="v3-latest"
DRY_RUN=false
SKIP_BUILD=false

usage() {
  cat <<'EOF'
Использование: release.sh [ПАРАМЕТРЫ]

Параметры:
  --dry-run       Подготовить dist, посчитать checksums.txt, вывести список файлов и хеши без выгрузки в GitHub
  --tag <tag>     Имя тега релиза на GitHub (по умолчанию: v3-latest)
  --skip-build    Пропустить запуск build.sh (использовать уже собранные файлы в dist/)
  -h, --help      Показать эту справку
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --tag)
      [[ $# -ge 2 ]] || { echo "ОШИБКА: отсутствует значение для --tag" >&2; exit 1; }
      TAG="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ОШИБКА: неизвестный параметр: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$DRY_RUN" == false ]]; then
  if [[ "$BRANCH" != "main" ]]; then
    echo "ОШИБКА: релиз v3 выполняется только из ветки main (текущая ветка: $BRANCH)" >&2
    exit 1
  fi
  if [[ -n "$(git -C "$REPO" status --porcelain -- go ':!go/dist' ':!.tmp')" ]]; then
    echo "ОШИБКА: в go/ есть незакоммиченные изменения" >&2
    exit 1
  fi
fi

TARGETS=(
  "remoteagents-darwin-amd64"
  "remoteagents-darwin-arm64"
  "remoteagents-linux-amd64"
  "remoteagents-linux-arm64"
  "remoteagents-windows-amd64.exe"
)

mkdir -p "$DIST_DIR"

if [[ "$SKIP_BUILD" == false ]]; then
  if [[ -x "$HERE/build.sh" ]]; then
    echo "==> Сборка 5 целей через build.sh..."
    timeout 420 flock --close /tmp/heavy-tests.lock bash "$HERE/build.sh"
  elif [[ "$DRY_RUN" == true ]]; then
    # В режиме dry-run при отсутствии build.sh создаём фиктивные цели, если их ещё нет
    for t in "${TARGETS[@]}"; do
      if [[ ! -f "$DIST_DIR/$t" ]]; then
        echo "dummy binary for $t" > "$DIST_DIR/$t"
      fi
    done
  else
    echo "ОШИБКА: $HERE/build.sh не найден или не исполняемый" >&2
    exit 1
  fi
fi

for t in "${TARGETS[@]}"; do
  if [[ ! -f "$DIST_DIR/$t" ]]; then
    echo "ОШИБКА: целевой файл $t отсутствует в $DIST_DIR" >&2
    exit 1
  fi
done

if [[ ! -f "$DIST_DIR/version.txt" ]]; then
  COMMIT_COUNT=$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo "1")
  echo "3.0.$COMMIT_COUNT" > "$DIST_DIR/version.txt"
fi
VERSION=$(tr -d ' \r\n' < "$DIST_DIR/version.txt")

(
  cd "$DIST_DIR"
  sha256sum "${TARGETS[@]}" version.txt > checksums.txt
)

sign_done=false
if [[ -n "${RELEASE_KEY:-}" && -f "${RELEASE_KEY:-}" ]]; then
  if ssh-keygen -Y sign -n ra3-release -f "$RELEASE_KEY" "$DIST_DIR/checksums.txt" 2>/dev/null; then
    sign_done=true
  elif minisign -S -s "$RELEASE_KEY" -m "$DIST_DIR/checksums.txt" -x "$DIST_DIR/checksums.txt.sig" 2>/dev/null; then
    sign_done=true
  fi
elif command -v projenv >/dev/null 2>&1; then
  PROJ=""
  if projenv list 2>/dev/null | grep -q '^remoteagents'; then
    PROJ="remoteagents"
  elif projenv list 2>/dev/null | grep -q '^ra3'; then
    PROJ="ra3"
  fi
  if [[ -n "$PROJ" ]]; then
    if projenv run "$PROJ" -- ssh-keygen -Y sign -n ra3-release -f "$DIST_DIR/checksums.txt" >/dev/null 2>&1; then
      sign_done=true
    elif projenv run "$PROJ" -- minisign -S -m "$DIST_DIR/checksums.txt" >/dev/null 2>&1; then
      sign_done=true
    fi
  fi
fi

if [[ "$sign_done" == false ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    echo "dummy-signature" > "$DIST_DIR/checksums.txt.sig"
  else
    echo "ОШИБКА: не удалось подписать checksums.txt (настройте projenv или укажите RELEASE_KEY)" >&2
    exit 1
  fi
fi

ASSETS=(
  "$DIST_DIR/remoteagents-darwin-amd64"
  "$DIST_DIR/remoteagents-darwin-arm64"
  "$DIST_DIR/remoteagents-linux-amd64"
  "$DIST_DIR/remoteagents-linux-arm64"
  "$DIST_DIR/remoteagents-windows-amd64.exe"
  "$DIST_DIR/version.txt"
  "$DIST_DIR/checksums.txt"
)
if [[ -f "$DIST_DIR/checksums.txt.sig" ]]; then
  ASSETS+=("$DIST_DIR/checksums.txt.sig")
elif [[ -f "$DIST_DIR/checksums.txt.minisig" ]]; then
  ASSETS+=("$DIST_DIR/checksums.txt.minisig")
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "=== Список файлов релиза ($TAG) ==="
  for a in "${ASSETS[@]}"; do
    echo "  $(basename "$a") ($(stat -c%s "$a" 2>/dev/null || wc -c < "$a") bytes)"
  done
  echo
  echo "=== checksums.txt ==="
  cat "$DIST_DIR/checksums.txt"
  echo
  echo "Готово (--dry-run: файлы сформированы, загрузка пропущена)."
  exit 0
fi

SHORT_SHA=$(git -C "$REPO" rev-parse --short HEAD)
SHA_CHECKSUMS=$(sha256sum "$DIST_DIR/checksums.txt" | cut -d' ' -f1)

git -C "$REPO" tag -f "$TAG" HEAD
git -C "$REPO" push -f origin "refs/tags/$TAG"

if ! gh release view "$TAG" >/dev/null 2>&1; then
  gh release create "$TAG" --prerelease --title "RemoteAgents v3 ($TAG)" --notes "RemoteAgents v3: тестовые сборки."
fi

echo "==> Загрузка ассетов в релиз $TAG..."
gh release upload "$TAG" "${ASSETS[@]}" --clobber

NOTES="Версия: $VERSION, коммит $SHORT_SHA, checksums SHA-256 $SHA_CHECKSUMS."
gh release edit "$TAG" --prerelease --notes "$NOTES"

echo "==> Скачивание и сверка SHA-256..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

gh release download "$TAG" -p "checksums.txt" -D "$TMP_DIR"
DOWNLOADED_SHA=$(sha256sum "$TMP_DIR/checksums.txt" | cut -d' ' -f1)
if [[ "$DOWNLOADED_SHA" != "$SHA_CHECKSUMS" ]]; then
  echo "ОШИБКА: SHA-256 скачанного checksums.txt ($DOWNLOADED_SHA) != локального ($SHA_CHECKSUMS)" >&2
  exit 1
fi

gh release download "$TAG" -p "remoteagents-linux-amd64" -D "$TMP_DIR"
(cd "$TMP_DIR" && sha256sum -c <(grep "remoteagents-linux-amd64" "$DIST_DIR/checksums.txt"))

echo "==> Релиз $TAG успешно опубликован и проверен."
echo "Релиз: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "jeromwork/AiServerAutoSettings")/releases/tag/$TAG"
