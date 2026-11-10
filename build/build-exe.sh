#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
version=${REMOTEAGENTS_BUNDLE_VERSION:-$(date -u +%Y%m%d.%H%M%S)-$(git -C "$repo" rev-parse --short HEAD)}
out=${REMOTEAGENTS_BUILD_OUT:-$here/out}
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
mkdir -p "$out" "$repo/release"
out=$(cd "$out" && pwd)
for product in RemoteAgents RemoteVPN; do
  mkdir -p "$out/$product"
  "$here/make-bundle.sh" "$version" "$out/$product" --product "$product"
  if [[ "$product" == RemoteAgents ]]; then cp "$out/$product/$version.zip" "$out/initial-bundle.zip"; fi
  "$dotnet" publish "$repo/app/launcher/RemoteAgents.Launcher.csproj" -c Release -p:ProductName="$product" -p:BundlePath="$out/$product/$version.zip" -o "$out/$product/publish"
  cp "$out/$product/publish/$product.exe" "$out/$product.exe"
  cp "$out/$product.exe" "$repo/release/$product.exe"
done
# Preserve the existing optional SSH update distribution for the server product.
python3 "$here/bundle.py" attach "$out/RemoteAgents/$version.zip" "$out/RemoteAgents.exe" "$out/$version.zip"
cp "$out/$version.zip" "$out/bundle.zip"
cp "$here/Start.cmd" "$repo/release/Start.cmd"
sha256sum "$repo/release/RemoteAgents.exe" "$repo/release/RemoteVPN.exe"
