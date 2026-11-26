#!/usr/bin/env bash
# release.sh — выпуск релиза v3 в GitHub Releases (тег v3-latest).
# Образец: lab/release.sh. Запуск только координатором из ветки main.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || (cd "$HERE/.." && pwd))

# Resolve GitHub's repository from this checkout's origin, regardless of caller.
gh_repo() (
  cd -- "$REPO"
  unset GH_REPO
  gh "$@"
)

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
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ "$DRY_RUN" == true ]]; then
  DIST_DIR=$(mktemp -d); CLEANUP_DIRS+=("$DIST_DIR")
  if [[ "$SKIP_BUILD" == true ]]; then cp -a "$HERE/dist/." "$DIST_DIR/"; fi
else
  DIST_DIR="$HERE/dist"; mkdir -p "$DIST_DIR"
fi

if [[ "$SKIP_BUILD" == false ]]; then
  if [[ -x "$HERE/build.sh" ]]; then
    echo "==> Сборка 5 целей через build.sh..."
    timeout 420 bash "$HERE/build.sh"
    [[ "$DRY_RUN" == true ]] && cp -a "$HERE/dist/." "$DIST_DIR/"
  else
    echo "ОШИБКА: $HERE/build.sh не найден или не исполняемый" >&2; exit 1
  fi
fi

for t in "${TARGETS[@]}"; do
  [[ -f "$DIST_DIR/$t" ]] || { echo "ОШИБКА: целевой файл $t отсутствует в $DIST_DIR" >&2; exit 1; }
done

# Always query the actual binary, including with --skip-build; never trust version.txt.
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || {
  echo "ОШИБКА: для проверки версии требуется Linux/amd64" >&2; exit 1;
}
VERSION=$(timeout 5 "$DIST_DIR/remoteagents-linux-amd64" version) || {
  echo "ОШИБКА: не удалось получить версию сборки" >&2; exit 1;
}
[[ "$VERSION" =~ ^3\.0\.[0-9]+$ ]] || {
  echo "ОШИБКА: недопустимая версия сборки" >&2; exit 1;
}
printf '%s\n' "$VERSION" > "$DIST_DIR/version.txt"
(cd "$DIST_DIR" && sha256sum "${TARGETS[@]}" version.txt > checksums.txt)

# Dry-run does not access signing secrets or create a pretend signature.
if [[ "$DRY_RUN" == false ]]; then
  command -v projenv >/dev/null || { echo "ОШИБКА: требуется projenv" >&2; exit 1; }
  PROJ=""
  projects=$(projenv list)
  if grep -q '^remoteagents' <<< "$projects"; then PROJ="remoteagents"
  elif grep -q '^ra3' <<< "$projects"; then PROJ="ra3"; fi
  [[ -n "$PROJ" ]] || { echo "ОШИБКА: проект подписи не найден в projenv" >&2; exit 1; }
  rm -f -- "$DIST_DIR/checksums.txt.sig"
  projenv run "$PROJ" -- bash -c '
    set -euo pipefail
    umask 077
    key_dir=$(mktemp -d)
    trap '\''rm -rf -- "$key_dir"'\'' EXIT
    trap '\''exit 130'\'' INT
    trap '\''exit 143'\'' TERM
    trap '\''exit 129'\'' HUP
    if [[ -n "${RELEASE_KEY_B64:-}" ]]; then
      # projenv stores single-line values only: the key is kept as base64.
      printf "%s" "$RELEASE_KEY_B64" | base64 -d > "$key_dir/key"
      k=file
    else
      k="${RELEASE_KEY:-${KEY:-}}"
    fi
    [[ -n "$k" ]] || exit 1
    if [[ $k == file ]]; then
      :
    elif [[ -f "$k" ]]; then
      cp -- "$k" "$key_dir/key"
    else
      printf "%s\n" "$k" > "$key_dir/key"
    fi
    ssh-keygen -Y sign -n ra3-release -f "$key_dir/key" "$1"
  ' _ "$DIST_DIR/checksums.txt" >/dev/null 2>&1 || {
    echo "ОШИБКА: не удалось подписать checksums.txt через projenv" >&2; exit 1;
  }
  ssh-keygen -Y verify -n ra3-release -f "$HERE/keys/allowed_signers" -I ra3 \
    -s "$DIST_DIR/checksums.txt.sig" < "$DIST_DIR/checksums.txt"
fi

ASSETS=()
for t in "${TARGETS[@]}"; do ASSETS+=("$DIST_DIR/$t"); done
ASSETS+=("$DIST_DIR/version.txt" "$DIST_DIR/checksums.txt")
if [[ "$DRY_RUN" == false ]]; then ASSETS+=("$DIST_DIR/checksums.txt.sig"); fi

if [[ "$DRY_RUN" == true ]]; then
  echo "=== Список файлов релиза ($TAG) ==="
  for a in "${ASSETS[@]}"; do
    echo "  $(basename "$a") ($(stat -c%s "$a" 2>/dev/null || wc -c < "$a") bytes)"
  done
  echo "  checksums.txt.sig (будет создан через projenv при публикации)"
  echo && echo "=== checksums.txt ===" && cat "$DIST_DIR/checksums.txt" && echo
  echo "Готово (--dry-run: файлы сформированы, загрузка пропущена)."
  exit 0
fi

SHORT_SHA=$(git -C "$REPO" rev-parse --short HEAD)
SHA_CHECKSUMS=$(sha256sum "$DIST_DIR/checksums.txt" | cut -d' ' -f1)

git -C "$REPO" tag -f "$TAG" HEAD
git -C "$REPO" push -f origin "refs/tags/$TAG"

if ! gh_repo release view "$TAG" >/dev/null 2>&1; then
  gh_repo release create "$TAG" --prerelease --title "RemoteAgents v3 ($TAG)" --notes "RemoteAgents v3: тестовые сборки."
fi

echo "==> Загрузка ассетов в релиз $TAG..."
gh_repo release upload "$TAG" "${ASSETS[@]}" --clobber

NOTES="Версия: $VERSION, коммит $SHORT_SHA, checksums SHA-256 $SHA_CHECKSUMS."
gh_repo release edit "$TAG" --prerelease --notes "$NOTES"

echo "==> Скачивание и сверка SHA-256..."
TMP_DIR=$(mktemp -d); CLEANUP_DIRS+=("$TMP_DIR")

for a in "${ASSETS[@]}"; do
  name=$(basename "$a")
  gh_repo release download "$TAG" -p "$name" -D "$TMP_DIR"
  cmp -s -- "$a" "$TMP_DIR/$name" || {
    echo "ОШИБКА: скачанный $name отличается от опубликованного файла" >&2; exit 1;
  }
done
(cd "$TMP_DIR" && sha256sum -c checksums.txt)
ssh-keygen -Y verify -n ra3-release -f "$HERE/keys/allowed_signers" -I ra3 \
  -s "$TMP_DIR/checksums.txt.sig" < "$TMP_DIR/checksums.txt"

echo "==> Релиз $TAG успешно опубликован и проверен."
echo "Релиз: https://github.com/$(gh_repo repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "jeromwork/AiServerAutoSettings")/releases/tag/$TAG"
