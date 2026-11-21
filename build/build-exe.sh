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
default_out="$here/out"
[[ "$RELEASE_CHANNEL" != "test" ]] || default_out="$here/out-test"
out=${REMOTEAGENTS_BUILD_OUT:-$default_out}
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
if [[ "$RELEASE_CHANNEL" == "test" ]]; then
  test_out=$(realpath -m -- "$out")
  main_out=$(realpath -m -- "$here/out")
  release_dir=$(realpath -m -- "$repo/release")
  if [[ "$test_out" == "$main_out" || "$test_out" == "$main_out/"* || "$test_out" == "$release_dir" || "$test_out" == "$release_dir/"* ]]; then
    echo 'Выходная папка test не может находиться в build/out или release' >&2
    exit 1
  fi
fi
mkdir -p "$out"
out=$(cd "$out" && pwd)

product="$RELEASE_PRODUCT"
exe_name="$RELEASE_EXE"

# Pinned third-party binaries (build/bundle-binaries.json; sing-box for VPN-first before the first SSH):
# downloaded once into the build cache, accepted only with the pinned SHA-256, embedded in the EXE only.
python3 "$here/bundle.py" fetch

mkdir -p "$out/$product"
"$here/make-bundle.sh" "$version" "$out/$product" --product "$product" --channel "$RELEASE_CHANNEL" --binaries
python3 "$here/bundle.py" verify-initial "$out/$product/$version.zip"
cp "$out/$product/$version.zip" "$out/initial-bundle.zip"
# Channel marker: release scripts refuse a build whose channel differs from the requested one.
rm -f -- "$out/channel.txt"

"$dotnet" publish "$repo/app/launcher/RemoteAgents.Launcher.csproj" -c Release \
  -p:ProductName="$product" \
  -p:AssemblyName="$product" \
  -p:UpdateChannel="$RELEASE_CHANNEL" \
  -p:BundlePath="$out/$product/$version.zip" \
  -o "$out/$product/publish"

cp "$out/$product/publish/$exe_name" "$out/$exe_name"
if [[ "$RELEASE_CHANNEL" == "main" ]]; then
  mkdir -p "$repo/release"
  cp "$out/$exe_name" "$repo/release/$exe_name"
  cp "$here/Start.cmd" "$repo/release/Start.cmd"
fi

# One program, one OTA root.
python3 "$here/bundle.py" attach "$out/$product/$version.zip" "$out/$exe_name" "$out/$version.zip" --product "$product"
cp "$out/$version.zip" "$out/bundle.zip"
sha256sum "$out/$exe_name"
printf '%s\n' "$RELEASE_CHANNEL" > "$out/channel.txt"
