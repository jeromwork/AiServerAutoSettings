#!/usr/bin/env bash
# Build release assets without changing the host system or downloading tools.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

fail() { printf 'build: %s\n' "$*" >&2; exit 1; }
targets=(windows/amd64 linux/amd64 linux/arm64 darwin/amd64 darwin/arm64)
case "${1:-}" in
  '') [[ $# == 0 ]] || fail 'usage: build.sh [--target os/arch]' ;;
  --target)
    [[ $# == 2 ]] || fail 'usage: build.sh [--target os/arch]'
    case "$2" in
      windows/amd64|linux/amd64|linux/arm64|darwin/amd64|darwin/arm64) targets=("$2") ;;
      *) fail "unsupported target: $2" ;;
    esac ;;
  --help|-h) printf 'usage: build.sh [--target os/arch]\n'; exit 0 ;;
  *) fail 'usage: build.sh [--target os/arch]' ;;
esac
source tools/versions.env
[[ $(go env GOVERSION) == "$GO_VERSION" ]] || fail "Go $GO_VERSION is required"
version=${VERSION:-$(git describe --tags --always --dirty)}
[[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || fail 'invalid VERSION'
remote=$(git remote get-url origin)
case "$remote" in
  https://*|http://*|ssh://*) repo=${remote#*://}; repo=${repo#*/} ;;
  *@*:*) repo=${remote#*:} ;;
  *) fail 'origin must identify an owner/repository' ;;
esac
repo=${repo%.git}
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'invalid release repository in origin'
# R0 supplies one or more minisign public keys, with optional comment lines.
# Before R0, development builds have no trusted release keys.
keys=''
if [[ -f keys/release.pub ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == 'untrusted comment:'* ]] && continue
    [[ $line =~ ^[A-Za-z0-9+/]{56}$ ]] || fail 'invalid minisign public key'
    keys+="${keys:+,}$line"
  done < keys/release.pub
  [[ -n $keys ]] || fail 'release.pub contains no public keys'
else
  printf 'build: warning: keys/release.pub absent (R0); no trusted release keys embedded\n' >&2
fi
ldflags="-X main.version=$version -X main.releaseRepo=$repo -X main.pubKeys=$keys"

exec 9>/tmp/heavy-tests.lock
timeout 420 flock -x 9
mkdir -p .tmp dist
work=$(mktemp -d "$PWD/.tmp/build.XXXXXX")
resource=''
cleanup() {
  [[ -z $resource ]] || rm -f -- "$resource"
  rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for target in "${targets[@]}"; do
  os=${target%/*}
  arch=${target#*/}
  name="remoteagents-$os-$arch"
  if [[ $os == windows ]]; then
    name+=.exe
    candidate="cmd/remoteagents/rsrc_windows_$arch.syso"
    [[ ! -e $candidate ]] || fail "resource already exists: $candidate"
    (cd cmd/remoteagents && timeout 420 go-winres make --in winres/winres.json \
      --arch "$arch" --out "$work/rsrc")
    resource="cmd/remoteagents/rsrc_windows_$arch.syso"
    cp -- "$work/rsrc_windows_$arch.syso" "$resource"
  fi
  printf 'Building %s (%s)\n' "$target" "$version"
  GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 timeout 420 go build \
    -mod=readonly -trimpath -ldflags "$ldflags" -o "$work/$name" ./cmd/remoteagents
  if [[ -n $resource ]]; then
    rm -f -- "$resource"
    resource=''
  fi
  mv -- "$work/$name" "dist/$name"
done
printf 'OK: %s asset(s) in dist/\n' "${#targets[@]}"
