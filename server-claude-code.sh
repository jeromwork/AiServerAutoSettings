#!/usr/bin/env bash
# Official native Claude Code installer, executed only as the selected app user.
set -Eeuo pipefail
[[ $(id -u) == 0 ]] || exit 3
target=${1:-remoteagents}
[[ $target == remoteagents ]] || exit 4
[[ $(id -u "$target") != 0 ]] || exit 4
home=$(getent passwd "$target" | cut -d: -f6)
[[ $home == /home/$target ]] || exit 5
command -v curl >/dev/null || { apt-get update; apt-get install -y --no-install-recommends curl ca-certificates; }
runuser -u "$target" -- env HOME="$home" bash -s <<'USER_INSTALL'
set -Eeuo pipefail
umask 077
if [[ -x "$HOME/.local/bin/claude" ]]; then
    "$HOME/.local/bin/claude" --version
    exit 0
fi
stage=$(mktemp -d /tmp/remoteagents-claude-code.XXXXXXXX)
trap 'rm -f -- "$stage/install.sh"; rmdir -- "$stage"' EXIT
curl -q --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 https://claude.ai/install.sh -o "$stage/install.sh"
# stable is the vendor-supported channel. This is never run as root.
timeout 900 bash "$stage/install.sh" stable
"$HOME/.local/bin/claude" --version
USER_INSTALL
