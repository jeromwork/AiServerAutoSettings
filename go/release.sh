#!/usr/bin/env bash
# release.sh — выпуск релиза v3 в GitHub Releases (тег v3-latest).
# Образец: lab/release.sh. Запуск только координатором из ветки main.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || (cd "$HERE/.." && pwd))

TAG="v3-latest"
DRY_RUN=false
SKIP_BUILD=false

usage() {
  cat <<'EOF'
Использование: release.sh [ПАРАМЕТРЫ]
  --dry-run       Подготовить dist, посчитать checksums.txt, вывести список файлов и хеши без выгрузки в GitHub
  --tag <tag>     Имя тега релиза на GitHub (по умолчанию: v3-latest)
  --skip-build    Пропустить запуск build.sh (использовать уже собранные файлы в dist/)
  -h, --help      Показать эту справку
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --tag) [[ $# -ge 2 ]] || { echo "ОШИБКА: отсутствует значение для --tag" >&2; exit 1; }; TAG="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ОШИБКА: неизвестный параметр: $1" >&2; usage >&2; exit 1 ;;
  esac
done

BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$DRY_RUN" == false ]]; then
  [[ "$BRANCH" == "main" ]] || { echo "ОШИБКА: релиз v3 выполняется только из ветки main (текущая ветка: $BRANCH)" >&2; exit 1; }
  [[ -z "$(git -C "$REPO" status --porcelain -- go ':!go/dist' ':!.tmp')" ]] || { echo "ОШИБКА: в go/ есть незакоммиченные изменения" >&2; exit 1; }
fi

TARGETS=(
  "remoteagents-darwin-amd64"
  "remoteagents-darwin-arm64"
  "remoteagents-linux-amd64"
  "remoteagents-linux-arm64"
  "remoteagents-windows-amd64.exe"
)

CLEANUP_DIRS=()
cleanup() { for d in "${CLEANUP_DIRS[@]}"; do rm -rf -- "$d"; done; }
trap cleanup EXIT

if [[ "$DRY_RUN" == true ]]; then
  DIST_DIR=$(mktemp -d); CLEANUP_DIRS+=("$DIST_DIR")
  [[ "$SKIP_BUILD" == true && -d "$HERE/dist" ]] && cp -a "$HERE/dist/." "$DIST_DIR/" 2>/dev/null || true
else
  DIST_DIR="$HERE/dist"; mkdir -p "$DIST_DIR"
fi

if [[ "$SKIP_BUILD" == false ]]; then
  if [[ -x "$HERE/build.sh" ]]; then
    echo "==> Сборка 5 целей через build.sh..."
    timeout 420 flock --close /tmp/heavy-tests.lock bash "$HERE/build.sh"
    [[ "$DRY_RUN" == true ]] && cp -a "$HERE/dist/." "$DIST_DIR/"
  elif [[ "$DRY_RUN" == true ]]; then
    for t in "${TARGETS[@]}"; do echo "dummy binary for $t" > "$DIST_DIR/$t"; done
  else
    echo "ОШИБКА: $HERE/build.sh не найден или не исполняемый" >&2; exit 1
  fi
fi

for t in "${TARGETS[@]}"; do
  [[ -f "$DIST_DIR/$t" ]] || { echo "ОШИБКА: целевой файл $t отсутствует в $DIST_DIR" >&2; exit 1; }
done

if [[ -x "$DIST_DIR/remoteagents-linux-amd64" ]]; then
  bin_ver=$("$DIST_DIR/remoteagents-linux-amd64" version 2>/dev/null || true)
  [[ "$bin_ver" =~ ^3\.0\.[0-9]+ ]] && echo "$bin_ver" > "$DIST_DIR/version.txt"
fi

if [[ ! -f "$DIST_DIR/version.txt" ]]; then
  COMMIT_COUNT=$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo "1")
  echo "3.0.$COMMIT_COUNT" > "$DIST_DIR/version.txt"
fi
VERSION=$(tr -d ' \r\n' < "$DIST_DIR/version.txt")

(cd "$DIST_DIR" && sha256sum "${TARGETS[@]}" version.txt > checksums.txt)

sign_done=false
sign_target="$DIST_DIR/checksums.txt"

if [[ -n "${RELEASE_KEY:-}" ]]; then
  if [[ -f "$RELEASE_KEY" ]]; then
    ssh-keygen -Y sign -n ra3-release -f "$RELEASE_KEY" "$sign_target" 2>/dev/null && sign_done=true
  else
    key_tmp=$(mktemp); chmod 600 "$key_tmp"; printf '%s\n' "$RELEASE_KEY" > "$key_tmp"
    ssh-keygen -Y sign -n ra3-release -f "$key_tmp" "$sign_target" 2>/dev/null && sign_done=true
    rm -f -- "$key_tmp"
  fi
fi

if [[ "$sign_done" == false ]] && command -v projenv >/dev/null 2>&1; then
  PROJ=""
  projenv list 2>/dev/null | grep -q '^remoteagents' && PROJ="remoteagents" || { projenv list 2>/dev/null | grep -q '^ra3' && PROJ="ra3"; } || true
  if [[ -n "$PROJ" ]]; then
    projenv run "$PROJ" -- bash -c '
      k="${RELEASE_KEY:-${KEY:-}}"; t="$1"
      if [[ -f "$k" ]]; then ssh-keygen -Y sign -n ra3-release -f "$k" "$t"
      elif [[ -n "$k" ]]; then
        f=$(mktemp); chmod 600 "$f"; printf "%s\n" "$k" > "$f"
        ssh-keygen -Y sign -n ra3-release -f "$f" "$t"; r=$?; rm -f -- "$f"; exit $r
      else exit 1; fi' _ "$sign_target" >/dev/null 2>&1 && sign_done=true
  fi
fi

if [[ "$sign_done" == false ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    echo "dummy-signature" > "$DIST_DIR/checksums.txt.sig"
  else
    echo "ОШИБКА: не удалось подписать checksums.txt (настройте projenv или укажите RELEASE_KEY)" >&2; exit 1
  fi
fi

ASSETS=()
for t in "${TARGETS[@]}"; do ASSETS+=("$DIST_DIR/$t"); done
ASSETS+=("$DIST_DIR/version.txt" "$DIST_DIR/checksums.txt" "$DIST_DIR/checksums.txt.sig")

if [[ "$DRY_RUN" == true ]]; then
  echo "=== Список файлов релиза ($TAG) ==="
  for a in "${ASSETS[@]}"; do
    echo "  $(basename "$a") ($(stat -c%s "$a" 2>/dev/null || wc -c < "$a") bytes)"
  done
  echo && echo "=== checksums.txt ===" && cat "$DIST_DIR/checksums.txt" && echo
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
TMP_DIR=$(mktemp -d); CLEANUP_DIRS+=("$TMP_DIR")

gh release download "$TAG" -p "checksums.txt" -D "$TMP_DIR"
DOWNLOADED_SHA=$(sha256sum "$TMP_DIR/checksums.txt" | cut -d' ' -f1)
[[ "$DOWNLOADED_SHA" == "$SHA_CHECKSUMS" ]] || { echo "ОШИБКА: SHA-256 скачанного checksums.txt ($DOWNLOADED_SHA) != локального ($SHA_CHECKSUMS)" >&2; exit 1; }

gh release download "$TAG" -p "remoteagents-linux-amd64" -D "$TMP_DIR"
(cd "$TMP_DIR" && sha256sum -c <(grep "remoteagents-linux-amd64" "$DIST_DIR/checksums.txt"))

echo "==> Релиз $TAG успешно опубликован и проверен."
echo "Релиз: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "jeromwork/AiServerAutoSettings")/releases/tag/$TAG"
