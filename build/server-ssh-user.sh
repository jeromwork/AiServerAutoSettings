#!/usr/bin/env bash
set -eu
# Only public key and validated login arrive in stdin/environment. No password reaches this script.
case "$ra_user" in ''|*[!a-z0-9_-]*) exit 20;; esac
case "$ra_key" in 'ssh-ed25519 '*) ;; *) exit 21;; esac
if [ "$(id -u)" = 0 ]; then
    if ! id "$ra_user" >/dev/null 2>&1; then useradd -m -s /bin/bash "$ra_user"; fi
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
