#!/usr/bin/env bash
set -eu
# Only public key and validated login arrive in stdin/environment. No password reaches this script.
case "$ra_user" in ''|*[!a-z0-9_-]*) exit 20;; esac
case "$ra_key" in 'ssh-ed25519 '*) ;; *) exit 21;; esac
if [ "$(id -u)" = 0 ]; then
    # This helper runs before Python staging and before the worker's bootstrap.
    # Only administrative SSH is required on a clean Debian/Ubuntu systemd VPS.
    missing=
    for tool in python3 curl tar xz git flock cron sudo ip jq nft dbus-daemon; do
        command -v "$tool" >/dev/null 2>&1 || missing=1
    done
    for package in dbus-user-session libpam-systemd python3-cryptography; do
        [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" = 'install ok installed' ] || missing=1
    done
    if [ -n "$missing" ]; then
        command -v apt-get >/dev/null || { echo 'Bootstrap requires Debian/Ubuntu apt-get' >&2; exit 22; }
        export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
        apt-get update >&2
        apt-get install -y --no-install-recommends python3 curl ca-certificates tar xz-utils git util-linux cron sudo iproute2 jq nftables openssl dbus dbus-user-session libpam-systemd python3-cryptography >&2
    fi
    if ! id "$ra_user" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$ra_user"
        # Legacy agent installers accept only the canonical account. Never adopt
        # an unrelated existing user merely because its name matches.
        if [ "$ra_user" = remoteagents ] && [ "$(getent passwd "$ra_user" | cut -d: -f6)" = /home/remoteagents ]; then
            for managed_path in /var/lib/remote-agents /var/lib/remote-agents/managed-user-v1; do
                [ ! -L "$managed_path" ]
                if [ -e "$managed_path" ]; then
                    [ "$(stat -c %u "$managed_path")" = 0 ]
                    [ -z "$(find "$managed_path" -maxdepth 0 -perm /022 -print -quit)" ]
                fi
            done
            install -d -o root -g root -m 755 /var/lib/remote-agents
            [ ! -L /var/lib/remote-agents/managed-user-v1 ]
            printf '%s\n' 'remoteagents:/home/remoteagents:v1' > /var/lib/remote-agents/managed-user-v1
            chmod 644 /var/lib/remote-agents/managed-user-v1
        fi
    fi
    uid=$(id -u "$ra_user"); [ "$uid" != 0 ]
    home=$(getent passwd "$ra_user" | cut -d: -f6)
else
    [ "$(id -un)" = "$ra_user" ]; home=$HOME
fi
[ -d "$home" ]; [ ! -L "$home/.ssh" ]; [ ! -L "$home/.ssh/authorized_keys" ]
install -d -m 700 "$home/.ssh"
touch "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"
# Same lock as `remoteagents config export/revoke` (server/remoteagents_config.py): flock on the file itself.
# Revoke replaces the file by rename while holding the lock, so append only if the locked descriptor is still
# the current file; otherwise reopen. No concurrent writer loses a line.
ak="$home/.ssh/authorized_keys"; appended=
for _ in 1 2 3 4 5; do
    exec 9>>"$ak"
    flock -w 30 9
    if [ "$(stat -L -c %d:%i /dev/fd/9)" = "$(stat -c %d:%i "$ak")" ]; then
        if ! grep -qxF -- "$ra_key" "$ak"; then printf '\n%s\n' "$ra_key" >&9; fi
        appended=1
    fi
    exec 9>&-
    [ -n "$appended" ] && break
done
[ -n "$appended" ]
if [ "$(id -u)" = 0 ]; then
    chown "$ra_user:$(id -gn "$ra_user")" "$home/.ssh" "$home/.ssh/authorized_keys"
    loginctl enable-linger "$ra_user"
    systemctl start "user@$(id -u "$ra_user").service"
fi
