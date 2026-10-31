#!/bin/bash
# Public common account preparation; installs no agent and never handles credentials.
set -euo pipefail
umask 022
[ "$(id -u)" -eq 0 ] || { echo 'Account preparation requires root or passwordless sudo.' >&2; exit 41; }
state=/var/lib/remote-agents
user=remoteagents
home=/home/remoteagents
for path in /var /var/lib "$state" "$state/managed-user-v1" "$state/install.lock"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
        if [ -L "$path" ] || [ "$(stat -c %u "$path")" -ne 0 ] || [ -n "$(find "$path" -maxdepth 0 -perm /022 -print -quit)" ]; then
            echo 'The managed account state is not a safe root-owned path. Nothing was changed.' >&2
            exit 51
        fi
    fi
done
mkdir -p "$state"
exec 9> "$state/install.lock"
flock -n 9 || { echo 'Another preparation is running. Wait and retry.' >&2; exit 50; }
if id "$user" >/dev/null 2>&1; then
    if [ ! -f "$state/managed-user-v1" ] || [ "$(getent passwd "$user" | cut -d: -f6)" != "$home" ] || [ "$(id -u "$user")" -eq 0 ]; then
        echo 'An unmanaged remoteagents account already exists. It was left untouched.' >&2
        exit 44
    fi
else
    useradd --create-home --home-dir "$home" --shell /bin/bash "$user"
    printf '%s\n' 'remoteagents:/home/remoteagents:v1' > "$state/managed-user-v1"
fi
runuser -u "$user" -- env HOME="$home" sh -c 'umask 077; mkdir -p "$HOME/work" "$HOME/.local/share" "$HOME/.local/state"'
echo 'AGENT_ACCOUNT_READY=remoteagents'
