#!/usr/bin/env bash
# Public installer. Account pairing and provider logins are separate, unlogged steps.
set -Eeuo pipefail
umask 077
[[ $(id -u) == 0 ]] || { echo 'Root or passwordless sudo is required.' >&2; exit 41; }
target=${1:-remoteagents}
[[ $target == remoteagents ]] || exit 42
[[ -f /var/lib/remote-agents/managed-user-v1 && ! -L /var/lib/remote-agents/managed-user-v1 && $(stat -c %u /var/lib/remote-agents/managed-user-v1) == 0 ]] || exit 44
home=$(getent passwd "$target" | cut -d: -f6)
[[ $home == /home/$target && ! -L $home && $(id -u "$target") != 0 ]] || exit 43
if ! command -v curl >/dev/null || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates
fi
echo 'REMOTE_CHAT_STAGE=Installing Happier stable on the server'
runuser -u "$target" -- env HOME="$home" bash -s <<'INSTALL'
set -Eeuo pipefail
umask 077
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$HOME/work"
if [[ ! -x "$HOME/.local/bin/happier" ]]; then
    stage=$(mktemp -d /tmp/remoteagents-happier.XXXXXXXX)
    trap 'rm -f -- "$stage/install.sh"; rmdir -- "$stage"' EXIT
    curl -q --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 https://happier.dev/install -o "$stage/install.sh"
    # Vendor stable installer verifies release signatures; never executes as root.
    timeout 900 bash "$stage/install.sh" --yes
fi
timeout 10 "$HOME/.local/bin/happier" --version
INSTALL
echo 'REMOTE_CHAT_STAGE=Enabling startup after server restarts'
uid=$(id -u "$target")
loginctl enable-linger "$target"
systemctl start "user@${uid}.service"
user_run=(runuser -u "$target" -- env HOME="$home" PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus")
if [[ ! -f "$home/.config/systemd/user/happier-daemon.default.service" ]]; then
    timeout 30 "${user_run[@]}" "$home/.local/bin/happier" service install --yes
else
    # Reopening chats must never restart workers or interrupt active sessions.
    "${user_run[@]}" systemctl --user enable happier-daemon.default.service
    "${user_run[@]}" systemctl --user start happier-daemon.default.service
fi
"${user_run[@]}" systemctl --user is-active --quiet happier-daemon.default.service
echo 'REMOTE_CHAT_INSTALLED=1'
echo 'REMOTE_CHAT_WEB=https://cloud.happier.dev'
echo 'REMOTE_CHAT_PAIRING=Open the private sign-in window to connect your account'
