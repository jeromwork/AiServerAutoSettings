#!/usr/bin/env bash
# Common release channel definitions and verification library
set -euo pipefail

resolve_channel() {
  local channel="${1:-main}"
  case "$channel" in
    main|"")
      RELEASE_CHANNEL="main"
      RELEASE_PRODUCT="RemoteAgents"
      RELEASE_EXE="RemoteAgents.exe"
      RELEASE_TAG="main-latest"
      RELEASE_DIST_DEFAULT='~/.local/share/remote-agents/dist'
      RELEASE_SOURCE_BRANCH="main"
      RELEASE_SOURCE_REF="origin/main"
      ;;
    test)
      RELEASE_CHANNEL="test"
      RELEASE_PRODUCT="RemoteAgents"
      RELEASE_EXE="RemoteAgents.exe"
      RELEASE_TAG="test-latest"
      RELEASE_DIST_DEFAULT='~/.local/share/remote-agents/dist-test'
      RELEASE_SOURCE_BRANCH="int/vpn-master"
      RELEASE_SOURCE_REF="origin/int/vpn-master"
      ;;
    *)
      echo "Неизвестный канал: $channel (разрешены только main и test)" >&2
      return 1
      ;;
  esac
  export RELEASE_CHANNEL RELEASE_PRODUCT RELEASE_EXE RELEASE_TAG RELEASE_DIST_DEFAULT RELEASE_SOURCE_BRANCH RELEASE_SOURCE_REF
}

check_channel_isolation() {
  local channel="$1"
  local dist="$2"
  if [[ "$channel" == "test" ]]; then
    # Only the literal canonical remote path is accepted; never normalize aliases or '..'.
    if [[ "$dist" != '~/.local/share/remote-agents/dist-test' ]]; then
      echo "Для test разрешён только ~/.local/share/remote-agents/dist-test ($dist)" >&2
      return 1
    fi
  elif [[ "$channel" == "main" && "$dist" == *dist-test ]]; then
    echo "Для main запрещён путь test-канала ($dist)" >&2
    return 1
  fi
  return 0
}

require_channel_commit() {
  local channel="$1"
  local commit="$2"
  local repo="$3"

  resolve_channel "$channel" || return 1

  if [[ "$channel" == "main" ]]; then
    local current_branch
    current_branch=$(git -C "$repo" branch --show-current)
    [[ "$current_branch" == "main" ]] || { echo "Выкладка main разрешена только из ветки main (текущая: $current_branch)" >&2; return 1; }
    [[ $(git -C "$repo" rev-parse "$commit") == $(git -C "$repo" rev-parse HEAD) ]] || { echo 'Коммит не совпадает с main HEAD' >&2; return 1; }
    git -C "$repo" merge-base --is-ancestor "$commit" origin/main || { echo 'Коммит ещё не в origin/main' >&2; return 1; }
  elif [[ "$channel" == "test" ]]; then
    local ref="origin/int/vpn-master"
    local current_branch
    current_branch=$(git -C "$repo" branch --show-current)
    [[ "$current_branch" == "int/vpn-master" ]] || { echo "Выкладка test разрешена только из ветки int/vpn-master (текущая: $current_branch)" >&2; return 1; }
    git -C "$repo" rev-parse --verify "$ref" >/dev/null 2>&1 || { echo "Нет обязательной ссылки $ref" >&2; return 1; }
    [[ $(git -C "$repo" rev-parse "$commit") == $(git -C "$repo" rev-parse HEAD) ]] || { echo 'Коммит не совпадает с HEAD' >&2; return 1; }
    [[ $(git -C "$repo" rev-parse HEAD) == $(git -C "$repo" rev-parse "$ref") ]] || { echo "Коммит test-канала должен совпадать с $ref" >&2; return 1; }
    [[ -z $(git -C "$repo" status --porcelain) ]] || { echo 'Перед сборкой test-канала нужно чистое дерево' >&2; return 1; }
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  channel="${1:-main}"
  field="${2:-info}"
  resolve_channel "$channel" || exit 1
  case "$field" in
    channel) echo "$RELEASE_CHANNEL" ;;
    product) echo "$RELEASE_PRODUCT" ;;
    exe) echo "$RELEASE_EXE" ;;
    tag) echo "$RELEASE_TAG" ;;
    dist) echo "$RELEASE_DIST_DEFAULT" ;;
    branch) echo "$RELEASE_SOURCE_BRANCH" ;;
    ref) echo "$RELEASE_SOURCE_REF" ;;
    info)
      echo "RELEASE_CHANNEL=$RELEASE_CHANNEL"
      echo "RELEASE_PRODUCT=$RELEASE_PRODUCT"
      echo "RELEASE_EXE=$RELEASE_EXE"
      echo "RELEASE_TAG=$RELEASE_TAG"
      echo "RELEASE_DIST_DEFAULT=$RELEASE_DIST_DEFAULT"
      echo "RELEASE_SOURCE_BRANCH=$RELEASE_SOURCE_BRANCH"
      echo "RELEASE_SOURCE_REF=$RELEASE_SOURCE_REF"
      ;;
    *)
      echo "Неизвестное поле: $field" >&2
      exit 1
      ;;
  esac
fi
