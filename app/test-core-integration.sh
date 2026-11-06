#!/bin/sh
# All workers and states belong to this temporary test only. No network downloads.
set -eu
archive=${1:?Pass official syncthing-linux-amd64-v2.1.7.tar.gz}
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT HUP INT TERM
printf '%s  %s\n' 2edc416e7ed136b7c858ed5f3f02a3b8316589605e54c380228ceea7acbf0142 "$archive" | sha256sum -c -
tar -xOf "$archive" syncthing-linux-amd64-v2.1.7/syncthing > "$root/syncthing"
chmod 700 "$root/syncthing"
RA_TEST_SYNCTHING="$root/syncthing" timeout 240 "$HOME/.dotnet/dotnet" test "$(dirname "$0")/RemoteAgents.Tests" -m:1 -p:UseSharedCompilation=false --nologo
