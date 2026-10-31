#!/bin/sh
set -eu
# Nonroot, pinned official archive. No SSH or existing auth files touched.
[ "$(id -u)" -ne 0 ] || { echo 'Nonroot required' >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo 'Only amd64 pilot supported' >&2; exit 1; }
destination=${1:?Pass an explicit private binary directory}
mkdir -p "$destination"
destination=$(cd "$destination" && pwd -P)
if [ -x "$destination/syncthing" ]; then "$destination/syncthing" --version; exit 0; fi
temporary=$(mktemp -d)
trap 'rm -f "$temporary/archive.tar.gz"; rmdir "$temporary" 2>/dev/null || true' EXIT HUP INT TERM
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 'https://github.com/syncthing/syncthing/releases/download/v2.1.7/syncthing-linux-amd64-v2.1.7.tar.gz' -o "$temporary/archive.tar.gz"
printf '%s  %s\n' '2edc416e7ed136b7c858ed5f3f02a3b8316589605e54c380228ceea7acbf0142' "$temporary/archive.tar.gz" | sha256sum --check --status
tar -xOf "$temporary/archive.tar.gz" syncthing-linux-amd64-v2.1.7/syncthing > "$destination/syncthing.partial"
chmod 700 "$destination/syncthing.partial"
mv "$destination/syncthing.partial" "$destination/syncthing"
"$destination/syncthing" --version
