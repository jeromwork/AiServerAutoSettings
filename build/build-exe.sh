#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
source "$here/release-lib.sh"

channel="main"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      [[ $# -ge 2 ]] || { echo "Требуется имя канала после --channel" >&2; exit 2; }
      channel="$2"; shift 2 ;;
    --channel=*)
      channel="${1#*=}"; shift ;;
    *)
      shift ;;
  esac
done

resolve_channel "$channel" || exit 1

version=${REMOTEAGENTS_BUNDLE_VERSION:-$(date -u +%Y%m%d.%H%M%S)-$(git -C "$repo" rev-parse --short HEAD)}
out=${REMOTEAGENTS_BUILD_OUT:-$here/out}
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
mkdir -p "$out" "$repo/release"
out=$(cd "$out" && pwd)

product="$RELEASE_PRODUCT"
instance="$RELEASE_INSTANCE"
exe_name="$RELEASE_EXE"

# Pinned third-party binaries (build/bundle-binaries.json; sing-box for VPN-first before the first SSH):
# downloaded once into the build cache, accepted only with the pinned SHA-256, embedded in the EXE only.
python3 "$here/bundle.py" fetch

mkdir -p "$out/$product"
"$here/make-bundle.sh" "$version" "$out/$product" --product "$product" --channel "$RELEASE_CHANNEL" --binaries
python3 "$here/bundle.py" verify-initial "$out/$product/$version.zip"
cp "$out/$product/$version.zip" "$out/initial-bundle.zip"

"$dotnet" publish "$repo/app/launcher/RemoteAgents.Launcher.csproj" -c Release \
  -p:ProductName="$product" \
  -p:AssemblyName="$product" \
  -p:Instance="$instance" \
  -p:BundlePath="$out/$product/$version.zip" \
  -o "$out/$product/publish"

cp "$out/$product/publish/$exe_name" "$out/$exe_name"
cp "$out/$exe_name" "$repo/release/$exe_name"

# One program, one OTA root.
if [[ "$RELEASE_CHANNEL" == "test" ]]; then
  python3 "$here/bundle.py" attach "$out/$product/$version.zip" "$out/$exe_name" "$out/$version.zip" || cp "$out/$product/$version.zip" "$out/$version.zip"
else
  python3 "$here/bundle.py" attach "$out/RemoteAgents/$version.zip" "$out/RemoteAgents.exe" "$out/$version.zip"
fi
cp "$out/$version.zip" "$out/bundle.zip"
cp "$here/Start.cmd" "$repo/release/Start.cmd"
sha256sum "$repo/release/$exe_name"
