#!/usr/bin/env bash
# Optional official Claude Desktop beta. Run only after the owner's selection.
set -Eeuo pipefail
umask 022
[[ $(id -u) == 0 ]] || exit 3
server_user=${1:-remoteagents}
[[ $server_user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $server_user != root ]] || exit 2
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 && $(dpkg --print-architecture) == amd64 ]] || exit 4
server_home=$(getent passwd "$server_user" | cut -d: -f6)
[[ $(id -u "$server_user") != 0 && $server_home == /home/"$server_user" ]] || exit 5
key=/usr/share/keyrings/claude-desktop-archive-keyring.asc
source_file=/etc/apt/sources.list.d/claude-desktop.list
source_line='deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main'
fingerprint=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
# Root-owned destination chain, including the vendor package's post-install paths.
python3 -I - <<'TRUST'
import os,stat
from pathlib import Path
def check(p):
 s=p.lstat()
 assert not stat.S_ISLNK(s.st_mode) and s.st_uid==0 and not s.st_mode&0o022,str(p)
for text in ('/','/etc','/etc/default','/etc/apt','/etc/apt/sources.list.d','/usr','/usr/share','/usr/share/keyrings','/var','/var/lib',
 '/usr/share/keyrings/claude-desktop-archive-keyring.asc','/etc/apt/sources.list.d/claude-desktop.list','/etc/default/claude-desktop','/var/lib/claude-desktop'):
 p=Path(text)
 if os.path.lexists(p):
  check(p)
  if text=='/var/lib/claude-desktop' and p.is_dir():
   for child in p.rglob('*'): check(child)
TRUST
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
if ! command -v curl >/dev/null || ! command -v gpg >/dev/null; then
 apt-get update
 apt-get install -y --no-install-recommends ca-certificates curl gnupg
fi
stage=$(mktemp -d /tmp/remoteagents-claude-install.XXXXXXXX)
chmod 0700 "$stage"
trap 'rm -rf -- "$stage"' EXIT
mkdir -m 0700 "$stage/gnupg"
curl -q --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 90 \
 https://downloads.claude.ai/claude-desktop/key.asc -o "$stage/key.asc"
actual=$(gpg --batch --homedir "$stage/gnupg" --show-keys --with-colons "$stage/key.asc" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')
[[ $actual == "$fingerprint" ]] || { echo 'Anthropic signing key fingerprint mismatch.' >&2; exit 6; }
if [[ -e $source_file ]] && [[ $(cat "$source_file") != "$source_line" ]]; then
 echo 'Existing Claude repository differs; it was left unchanged.' >&2
 exit 7
fi
install -m 0644 "$stage/key.asc" "$key"
printf '%s\n' "$source_line" > "$source_file"
apt-get update
# apt verifies package integrity against the fingerprint-verified signed repository.
python3 -I - <<'CANDIDATE'
import apt
c=apt.Cache()['claude-desktop'].candidate
assert c and any(o.site=='downloads.claude.ai' and o.trusted for o in c.origins),'No trusted Anthropic package candidate'
CANDIDATE
# Do not pull QEMU/firmware for Cowork; no KVM is available on the current VPS.
apt-get install -y --no-install-recommends claude-desktop gnome-keyring
runuser -u "$server_user" -- env HOME="$server_home" python3 -I - "$server_home" <<'SHORTCUT'
import os,stat,sys
from pathlib import Path
desktop=Path(sys.argv[1])/'Desktop'
if not desktop.exists(): desktop.mkdir(mode=0o755)
s=desktop.lstat()
assert stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid() and not s.st_mode&0o022
p=desktop/'Claude.desktop'
fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o755)
with os.fdopen(fd,'w') as f:
 f.write('[Desktop Entry]\nType=Application\nName=Claude\nComment=Официальное приложение Anthropic\nExec=claude-desktop\nIcon=claude-desktop\nTerminal=false\nCategories=Development;\n')
os.chmod(p,0o755)
SHORTCUT
dpkg-query -W -f='CLAUDE_DESKTOP_INSTALLED=${Version}\n' claude-desktop
printf 'CLAUDE_DESKTOP_SHORTCUT=%s/Desktop/Claude.desktop\n' "$server_home"
printf 'CLAUDE_DESKTOP_NOT_SIGNED_IN_BY_INSTALLER=1\n'
