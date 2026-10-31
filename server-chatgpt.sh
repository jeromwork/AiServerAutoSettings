#!/usr/bin/env bash
# Official ChatGPT Linux preview; public installer, no account or project access.
set -Eeuo pipefail
umask 022
[[ $(id -u) == 0 ]] || exit 3
server_user=${1:-remoteagents}
[[ $server_user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $server_user != root ]] || exit 2
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 && $(dpkg --print-architecture) == amd64 ]] || exit 4
server_home=$(getent passwd "$server_user" | cut -d: -f6)
[[ $(id -u "$server_user") != 0 && $server_home == /home/"$server_user" ]] || exit 5
version=26.1027.30824
sha=4e139a44f7c917a643f2dd014ad32298dd30aec6d324d323524b190f7667684c
base=/opt/remote-agents/chatgpt-installer
# Validate all privileged destinations before trusting or replacing cached files.
python3 -I - "$base" <<'TRUST'
import os,stat,sys
from pathlib import Path
base=Path(sys.argv[1])
def check(p):
 s=p.lstat()
 assert not stat.S_ISLNK(s.st_mode) and s.st_uid==0 and not s.st_mode&0o022,str(p)
for text in ('/','/opt','/opt/remote-agents','/etc','/etc/default','/etc/apt','/etc/apt/sources.list.d','/usr','/usr/share','/usr/share/keyrings','/var','/var/lib'):
 p=Path(text)
 if os.path.lexists(p): check(p)
for text in ('/etc/default/chatgpt','/etc/apt/sources.list.d/chatgpt.sources','/usr/share/keyrings/chatgpt-archive-keyring.gpg','/var/lib/chatgpt',str(base)):
 p=Path(text)
 if os.path.lexists(p):
  check(p)
  if p.is_dir():
   for child in p.rglob('*'): check(child)
TRUST
install -d -m 0755 "$base"
package="$base/chatgpt_${version}_amd64.deb"
if [[ ! -f $package ]] || ! printf '%s  %s\n' "$sha" "$package" | sha256sum -c --status; then
 stage=$(mktemp -d /tmp/remoteagents-chatgpt-install.XXXXXXXX)
 chmod 0700 "$stage"
 trap 'rm -rf -- "$stage"' EXIT
 curl -q --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 600 \
  https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb -o "$stage/chatgpt.deb"
 printf '%s  %s\n' "$sha" "$stage/chatgpt.deb" | sha256sum -c
 [[ $(dpkg-deb -f "$stage/chatgpt.deb" Package) == chatgpt && $(dpkg-deb -f "$stage/chatgpt.deb" Version) == "$version" && $(dpkg-deb -f "$stage/chatgpt.deb" Architecture) == amd64 ]] || exit 6
 install -m 0644 "$stage/chatgpt.deb" "$package"
fi
if [[ $(dpkg-query -W -f='${Status}:${Version}' chatgpt 2>/dev/null || true) != "install ok installed:$version" ]]; then
 export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
 apt-get update
 apt-get install -y "$package"
fi
# Create a shortcut as its owner, never write into a user-controlled tree as root.
runuser -u "$server_user" -- env HOME="$server_home" python3 -I - "$server_home" <<'SHORTCUT'
import os,stat,sys
from pathlib import Path
home=Path(sys.argv[1]); desktop=home/'Desktop'
if not desktop.exists(): desktop.mkdir(mode=0o755)
s=desktop.lstat()
assert stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid() and not s.st_mode&0o022
p=desktop/'ChatGPT.desktop'
fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o755)
with os.fdopen(fd,'w') as f:
 f.write('[Desktop Entry]\nType=Application\nName=ChatGPT — Codex\nComment=Официальное приложение OpenAI\nExec=chatgpt\nIcon=chatgpt\nTerminal=false\nCategories=Development;\n')
os.chmod(p,0o755)
SHORTCUT
dpkg-query -W -f='CHATGPT_INSTALLED=${Version}\n' chatgpt
printf 'CHATGPT_SHORTCUT=%s/Desktop/ChatGPT.desktop\n' "$server_home"
printf 'CHATGPT_NOT_SIGNED_IN_BY_INSTALLER=1\n'
