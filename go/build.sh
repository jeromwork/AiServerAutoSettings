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
# C9: R0 supplies current and backup OpenSSH keys for the ra3 signer.
[[ -s keys/allowed_signers ]] || fail 'keys/allowed_signers is missing or empty (R0 required)'
keys=''
key_count=0
while read -r signer key_type key_data comment || [[ -n $signer ]]; do
  [[ -z $signer || $signer == \#* ]] && continue
  [[ $signer == ra3 ]] || fail 'allowed_signers: expected signer ra3'
  [[ $key_type =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))$ ]] ||
    fail 'allowed_signers: unsupported public key type'
  [[ $key_data =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || fail 'allowed_signers: invalid public key data'
  # Drop comments; keep the allowed_signers format, including line boundaries.
  keys+="${keys:+$'\n'}$signer $key_type $key_data"
  key_count=$((key_count + 1))
done < keys/allowed_signers
[[ $key_count == 2 ]] || fail 'allowed_signers must contain current and backup keys'
# Go's flag parser preserves spaces/newlines inside this quoted -X argument.
ldflags="-X main.version=$version -X main.releaseRepo=$repo -X 'main.pubKeys=$keys'"

exec 9>/tmp/heavy-tests.lock
flock -x 9
# One budget for all targets; waiting for the lock is outside that budget.
build() {
  mkdir -p .tmp dist
  work=$(mktemp -d "$PWD/.tmp/build.XXXXXX")
  resource=''
  embed=internal/singbox/embedded/sing-box.bin
  cleanup() {
    rm -f -- "$embed" "$embed.tmp"
    [[ -z $resource ]] || rm -f -- "$resource"
    rm -rf -- "$work"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for target in "$@"; do
    os=${target%/*}
    arch=${target#*/}
    name="remoteagents-$os-$arch"
    if [[ $os == windows ]]; then
      name+=.exe
      candidate="cmd/remoteagents/rsrc_windows_$arch.syso"
      [[ ! -e $candidate ]] || fail "resource already exists: $candidate"
      (cd cmd/remoteagents && go-winres make --in winres/winres.json \
        --arch "$arch" --out "$work/rsrc")
      resource="cmd/remoteagents/rsrc_windows_$arch.syso"
      cp -- "$work/rsrc_windows_$arch.syso" "$resource"
    fi
    # Each exe carries only its own pinned, sha256-verified sing-box.
    python3 -I tools/embed-singbox.py third_party/singbox.lock.json "$os" "$arch" \
      "$embed" "$PWD/.tmp/singbox-cache"
    printf 'Building %s (%s)\n' "$target" "$version"
    GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 go build -tags singbox_embed \
      -mod=readonly -trimpath -ldflags "$ldflags" -o "$work/$name" ./cmd/remoteagents
    if [[ -n $resource ]]; then
      rm -f -- "$resource"
      resource=''
    fi
    rm -f -- "$embed"
    mv -- "$work/$name" "dist/$name"
  done
  printf 'OK: %s asset(s) in dist/\n' "$#"
}
export -f build fail
export ldflags version
timeout --kill-after=5 420 bash -euo pipefail -c 'build "$@"' bash "${targets[@]}"
