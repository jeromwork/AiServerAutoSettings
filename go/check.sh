#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source tools/versions.env

if [[ "$(go env GOVERSION)" != "$GO_VERSION" ]]; then
  echo "Go $GO_VERSION is required" >&2
  exit 1
fi

gofmt_check() {
  local unformatted
  unformatted=$("$(go env GOROOT)/bin/gofmt" -l .)
  if [[ -n "$unformatted" ]]; then
    printf 'gofmt: needs formatting:\n%s\n' "$unformatted" >&2
    return 1
  fi
}

case "${1:-full}" in
  quick)
    package="${2:-./...}"
    gofmt_check
    go build -mod=readonly "$package"
    go vet -mod=readonly "$package"
    ;;
  full)
    exec 9>/tmp/heavy-tests.lock
    flock -x 9
    gofmt_check
    if ! golangci-lint version | grep -F "version $GOLANGCI_LINT_VERSION " >/dev/null; then
      echo "golangci-lint $GOLANGCI_LINT_VERSION is required" >&2
      exit 1
    fi
    if git ls-files --eol -- . | grep -E '(^i/|[[:space:]]w/)(crlf|mixed)[[:space:]]'; then
      echo "Go sources must use LF line endings" >&2
      exit 1
    fi
    for target in windows/amd64 linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do
      echo "Building $target"
      GOOS="${target%/*}" GOARCH="${target#*/}" CGO_ENABLED=0 go build -mod=readonly ./...
    done
    for os in windows linux darwin; do
      GOOS="$os" GOARCH=amd64 CGO_ENABLED=0 go vet -mod=readonly ./...
      GOOS="$os" GOARCH=amd64 CGO_ENABLED=0 golangci-lint run --tests=false ./...
    done
    ;;
  *)
    echo "usage: check.sh quick [package] | check.sh full" >&2
    exit 2
    ;;
esac

echo OK
