#!/bin/bash
# Remote Agents bootstrap v1. Public source only; stdin never contains credentials.
set -euo pipefail
umask 022
trap 'printf "Codex preparation failed at line %s. Existing account/work files were preserved.\n" "$LINENO" >&2' ERR
if [ "$(id -u)" -ne 0 ]; then
    echo 'This step requires root or passwordless sudo. No sudo policy is changed.' >&2
    exit 41
fi
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;; *) echo 'Supported: Ubuntu 22.04, 24.04 or 26.04.' >&2; exit 42 ;; esac
version=0.166.0
case "$(uname -m)" in
    x86_64) target=x86_64-unknown-linux-musl; digest=1d44b28bc4ac9937d7d3532264baa68a507ce364956a0d4ebb856f331cdee254 ;;
    aarch64|arm64) target=aarch64-unknown-linux-musl; digest=7821b77dda2e6283fb1f63f3165177a271da8833e857cf673c6ca1c9db3bfcc6 ;;
    *) echo 'Supported CPU: x86_64 or arm64.' >&2; exit 43 ;;
esac
echo '5/7 Checking Linux and preparing a separate Codex account...'
for tool in curl tar sha256sum python3 git; do
    if ! command -v "$tool" >/dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl tar python3 git
        break
    fi
done
state=/var/lib/remote-agents
user=remoteagents
home=/home/remoteagents
check_root_path() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        if [ -L "$1" ] || [ "$(stat -c %u "$1")" -ne 0 ] || [ -n "$(find "$1" -maxdepth 0 -perm /022 -print -quit)" ]; then
            echo 'An installation path is writable by another account or is a symlink. It was left untouched.' >&2
            exit 51
        fi
    fi
}
check_root_path "$state"
mkdir -p "$state"
chmod 755 "$state"
check_root_path "$state/windows-mcp"
mkdir -p "$state/windows-mcp"
chmod 755 "$state/windows-mcp"
exec 9> "$state/install.lock"
flock -n 9 || { echo 'Another installation is running. Wait and retry.' >&2; exit 50; }
if id "$user" >/dev/null 2>&1; then
    if [ ! -f "$state/managed-user-v1" ] || [ "$(getent passwd "$user" | cut -d: -f6)" != "$home" ] || [ "$(id -u "$user")" -eq 0 ]; then
        echo 'The remoteagents account already exists but is not managed by this installer. It was left untouched.' >&2
        exit 44
    fi
else
    useradd --create-home --home-dir "$home" --shell /bin/bash "$user"
    printf '%s\n' 'remoteagents:/home/remoteagents:v1' > "$state/managed-user-v1"
fi
# Never let privileged writes follow paths controlled by the Codex account.
runuser -u "$user" -- env HOME="$home" sh -c 'umask 077; mkdir -p "$HOME/work" "$HOME/.local/share" "$HOME/.local/state"'
release="/opt/remote-agents/codex/$version"
binary="$release/bin/codex"
for path in /opt /opt/remote-agents /opt/remote-agents/codex "$release" /usr/local /usr/local/lib /usr/local/lib/remoteagents /usr/local/bin; do check_root_path "$path"; done
if [ -d "$release" ] && [ -n "$(find "$release" \( -type l -o ! -user root -o -perm /022 \) -print -quit)" ]; then
    echo 'The cached release has unsafe ownership or permissions. It was left untouched.' >&2
    exit 52
fi
verified=false
check_package() {
    python3 - "$1" "$version" "$target" <<'PACKAGE_CHECK'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
try:
    manifest = json.loads((root / 'codex-package.json').read_text(encoding='utf-8'))
    assert str(manifest['version']) == sys.argv[2]
    assert manifest['target'] == sys.argv[3] and manifest['entrypoint'] == 'bin/codex'
    for name in ('bin/codex', 'bin/codex-code-mode-host', 'bin/codex-exec-server', 'codex-path/rg', 'codex-resources/bwrap'):
        path = root / name
        assert path.is_file() and not path.is_symlink() and os.access(path, os.X_OK)
except (OSError, ValueError, KeyError, AssertionError):
    sys.exit(1)
PACKAGE_CHECK
}
if [ -f "$release/release.sha256" ] && check_package "$release" && (cd "$release" && sha256sum --status -c release.sha256); then
    if [ "$(runuser -u "$user" -- "$binary" --version)" = "codex-cli $version" ]; then verified=true; fi
fi
if [ "$verified" != true ]; then
    echo '6/7 Downloading the pinned official Codex release and checking SHA-256...'
    staging=$(mktemp -d /opt/remote-agents-codex.XXXXXXXX)
    chmod 755 "$staging"
    trap 'rm -rf -- "$staging"' EXIT
    archive="$staging/release.tar.gz"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$archive" "https://releases.openai.com/codex/releases/$version/codex-package-$target.tar.gz"
    printf '%s  %s\n' "$digest" "$archive" | sha256sum --check --status
    # The digest is pinned above to the official release asset. Extract into a fresh root-owned directory.
    tar -tzf "$archive" | while IFS= read -r entry; do case "$entry" in /*|../*|*/../*|*/..) exit 45 ;; esac; done
    mkdir "$staging/unpacked"
    tar --extract --gzip --file "$archive" --directory "$staging/unpacked" --no-same-owner
    manifest=$(find "$staging/unpacked" -type f -name codex-package.json -print -quit)
    [ -n "$manifest" ] || { echo 'The verified archive has no complete Codex package.' >&2; exit 46; }
    package=$(dirname "$manifest")
    [ -z "$(find "$package" \( -type l -o ! -type d -a ! -type f \) -print -quit)" ] || { echo 'The package contains unsupported links or special files.' >&2; exit 46; }
    check_package "$package" || { echo 'The official Codex package layout is incomplete.' >&2; exit 46; }
    [ "$(runuser -u "$user" -- "$package/bin/codex" --version)" = "codex-cli $version" ]
    (cd "$package" && find . -type f -exec sha256sum '{}' \; > "$staging/release.sha256")
    mkdir -p "$(dirname "$release")"
    cp "$staging/release.sha256" "$package/release.sha256"
    chmod -R go-w "$package"
    previous=''
    if [ -e "$release" ]; then previous="$release.previous.$(date +%s).$$"; mv "$release" "$previous"; fi
    if ! mv "$package" "$release"; then
        if [ -n "$previous" ]; then mv "$previous" "$release"; fi
        echo 'The previous Codex release was restored after a failed replacement.' >&2
        exit 46
    fi
else
    echo '6/7 Existing Codex installation passed checksum and version checks.'
fi
install -d -m 755 /usr/local/lib/remoteagents
cat > /usr/local/lib/remoteagents/codex-session <<'SESSION'
#!/bin/bash
set -euo pipefail
if [ "$(id -un)" != remoteagents ]; then echo 'Codex must run as remoteagents.' >&2; exit 47; fi
export HOME=/home/remoteagents
export PATH=/opt/remote-agents/codex/0.166.0/bin:/usr/local/bin:/usr/bin:/bin
cd "$HOME/work"
bridge_options=()
for marker in /var/lib/remote-agents/windows-mcp/windows-win-*; do
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    name=${marker##*/}
    [[ "$name" =~ ^windows-win-[a-f0-9]{28}$ ]] || { echo 'Invalid managed bridge name.' >&2; exit 50; }
    bridge_options+=(-c "mcp_servers.${name}.enabled=false")
done
case "${1:-chat}" in
    status) exec codex login status ;;
    auth-device) if codex login status; then exit 0; fi; codex login --device-auth; exec codex login status ;;
    chat) shift; codex login status || { echo 'Сначала выполните codex login --device-auth в терминале сервера и откройте ссылку в серверном Chrome.' >&2; exit 48; }; exec codex "${bridge_options[@]}" "$@" ;;
    *) echo 'Unknown session mode.' >&2; exit 49 ;;
esac
SESSION
chmod 755 /usr/local/lib/remoteagents/codex-session
if [ ! -e /usr/local/bin/codex ] && [ ! -L /usr/local/bin/codex ]; then ln -s "$binary" /usr/local/bin/codex; fi
runuser -u "$user" -- env HOME="$home" "$binary" --version
# A result, not a substitute for the checks performed on every run. Never contains credentials.
printf '{"schema":1,"bootstrap":1,"codexVersion":"%s","user":"remoteagents","work":"/home/remoteagents/work"}\n' "$version" > "$state/status.json.tmp"
mv "$state/status.json.tmp" "$state/status.json"
echo '7/7 Codex is installed and runs without root. Account sign-in is the next step.'
