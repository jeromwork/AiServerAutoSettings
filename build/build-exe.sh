#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
version=${REMOTEAGENTS_BUNDLE_VERSION:-$(date -u +%Y%m%d.%H%M%S)-$(git -C "$repo" rev-parse --short HEAD)}
out=${REMOTEAGENTS_BUILD_OUT:-$here/out}
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
mkdir -p "$out"
out=$(cd "$out" && pwd)
"$here/make-bundle.sh" "$version" "$out"
cp "$out/$version.zip" "$out/initial-bundle.zip"
"$dotnet" publish "$repo/app/launcher/RemoteAgents.Launcher.csproj" -c Release -p:BundlePath="$out/initial-bundle.zip" -o "$out/publish"
cp "$out/publish/RemoteAgents.exe" "$out/RemoteAgents.exe"
test -s "$out/RemoteAgents.exe"
# OTA includes the freshly built launcher; its own embedded ZIP contains modules only.
python3 "$here/bundle.py" attach "$out/initial-bundle.zip" "$out/RemoteAgents.exe" "$out/$version.zip"
cp "$out/$version.zip" "$out/bundle.zip"
sha256sum "$out/RemoteAgents.exe" "$out/$version.zip"
