#!/usr/bin/env bash
# Runs as the saved working SSH user. Installs no provider credentials and touches no daemon.
set -euo pipefail
umask 077
export PATH="$HOME/.local/share/remoteagents-accounts/node:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$HOME/.local/share/remoteagents-accounts"
exec 9> "$HOME/.local/share/remoteagents-accounts/bootstrap.lock"
flock -w 120 9
# Public progress for the detached wizard operation (server-wizard.sh run happier).
# "k/n text": stage k of n.
step() { if [[ -n ${REMOTEAGENTS_STEP_FILE:-} ]]; then printf '%s\n' "$1" > "$REMOTEAGENTS_STEP_FILE" || true; fi; }
step '1/3 Проверяю Node.js 22+ (при необходимости загрузка с nodejs.org)'
if ! command -v node >/dev/null || ! node -e 'if(+process.versions.node.split(".")[0]<22)process.exit(1)' >/dev/null 2>&1; then
    [[ $(uname -m) == x86_64 ]] || { echo 'Node.js >=22 required for this server architecture' >&2; exit 1; }
    # Same pinned official runtime as server-devtools.sh; no root/global Node replacement.
    version=24.22.2
    digest=48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75
    stage=$(mktemp -d "$HOME/.local/share/remoteagents-accounts/runtime.XXXXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    curl -q --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 180 "https://nodejs.org/download/release/v$version/node-v$version-linux-x64.tar.xz" -o "$stage/node.tar.xz"
    printf '%s  %s\n' "$digest" "$stage/node.tar.xz" | sha256sum --check --status
    tar -xJf "$stage/node.tar.xz" -C "$stage"
    mkdir -p "$HOME/.local/share/remoteagents-accounts/node"
    cp "$stage/node-v$version-linux-x64/bin/node" "$HOME/.local/share/remoteagents-accounts/node/node"
    rm -rf -- "$stage"
    trap - EXIT
fi
if [[ ! -x "$HOME/.local/bin/happier" ]]; then
    step '2/3 Скачиваю и проверяю Happier (happier.dev/install: ~120 МБ с GitHub)'
    stage=$(mktemp -d "$HOME/.local/share/remoteagents-accounts/install.XXXXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    curl -q --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 https://happier.dev/install -o "$stage/install.sh"
    # Output goes to the detached operation log (no secrets); its last line is the failure reason.
    timeout 900 bash "$stage/install.sh" --yes </dev/null
fi
step '3/3 Включаю автозапуск пользовательских служб'
# User manager is supplied by the existing server setup; enabling linger never disables other services.
loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
systemctl --user show-environment >/dev/null
