#!/usr/bin/env bash
# Build a single offline executable. No publishing or system changes.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$here/.."
if [[ $# != 2 ]]; then
  echo 'Использование: build/release.sh <windows|linux|darwin> <amd64|arm64>' >&2
  exit 1
fi
target_os=$1
target_arch=$2
case "$target_os/$target_arch" in
  windows/amd64|linux/amd64|darwin/amd64|darwin/arm64) ;;
  *) echo "Неподдерживаемая цель: $target_os/$target_arch" >&2; exit 1 ;;
esac
mkdir -p dist
# The temporary go:embed file is shared by release targets in this worktree.
exec 9>dist/release.lock
flock 9
out="$PWD/dist/$target_os-$target_arch"
mkdir -p "$out"
export DOTNET_CLI_HOME="$PWD/dist/dotnet-home"
export NUGET_PACKAGES="$PWD/dist/nuget"
export NUGET_HTTP_CACHE_PATH="$PWD/dist/nuget-http"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_PROCESSOR_COUNT=${DOTNET_PROCESSOR_COUNT:-2}
if [[ $target_os == windows ]]; then
  "${DOTNET:-dotnet}" publish internal/disk/explorer/disk-explorer.csproj --disable-build-servers \
    -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true \
    -p:IncludeNativeLibrariesForSelfExtract=true -p:NuGetAudit=false \
    -p:BaseIntermediateOutputPath="$out/obj/" \
    -p:BaseOutputPath="$out/dotnet-bin/" -o "$out/explorer"
fi
python3 -I "$here/bundle.py" "$target_os" "$target_arch" "$out"
cp "$out/bin.zip" internal/deps/bin.zip
trap 'rm -f internal/deps/bin.zip' EXIT
name=RemoteAgents
flags='-s -w'
if [[ $target_os == windows ]]; then
  name+=.exe
  flags+=' -H=windowsgui'
fi
CGO_ENABLED=0 GOOS="$target_os" GOARCH="$target_arch" \
  go build -trimpath -tags bundle -ldflags "$flags" -o "$out/$name" ./cmd/remoteagents
sha256sum "$out/$name" > "$out/$name.sha256"
python3 -I - "$out/$name" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
print('%s: %d байт (%.2f МиБ)' % (p, p.stat().st_size, p.stat().st_size / 2**20))
PY
