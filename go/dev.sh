#!/usr/bin/env bash
# Live development against an existing bench; never creates keys or changes networking.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source tools/versions.env

# S0 keeps the development toolchain separate from the system Go installation.
export GOROOT="${GOROOT:-$HOME/.local/opt/$GO_VERSION}"
export PATH="$GOROOT/bin:$HOME/.local/opt/go-tools:$PATH"
if [[ ! -x "$GOROOT/bin/go" ]] || [[ "$(go env GOVERSION)" != "$GO_VERSION" ]]; then
  echo "dev: toolchain: install $GO_VERSION in $GOROOT" >&2
  exit 1
fi

# Air invokes these in the same environment as the parent launcher.
case "${1:-}" in
  --build)
    : "${RA_DEV_BIN:?start dev.sh without --build}"
    flags=()
    if command -v gcc >/dev/null 2>&1; then
      export CGO_ENABLED=1 CC=gcc
      flags+=(-race)
    else
      echo 'dev: gcc unavailable; building without -race' >&2
    fi
    exec go build -mod=readonly "${flags[@]}" -o "$RA_DEV_BIN" ./cmd/remoteagents
    ;;
  --run)
    : "${RA_DEV_BIN:?start dev.sh without --run}"
    : "${RA_DEV_BENCH:?start dev.sh without --run}"
    exec "$RA_DEV_BIN" run --home "$RA_DEV_BENCH/home" --no-tun --safe \
      --dev-assets internal/webui/static --pprof 127.0.0.1:0 \
      --config "$RA_DEV_BENCH/config.json" --password-file "$RA_DEV_BENCH/pw"
    ;;
  '') ;;
  *) echo 'usage: B=/path/to/bench ./dev.sh' >&2; exit 2 ;;
esac

if [[ -z "${B:-}" ]] && [[ -r /var/tmp/ra3-bench.current ]]; then
  IFS= read -r B < /var/tmp/ra3-bench.current
fi
if [[ -z "${B:-}" || ! -d "$B" ]]; then
  echo 'dev: bench: set B to an existing bench directory (bench.sh up)' >&2
  exit 1
fi
export RA_DEV_BENCH
RA_DEV_BENCH=$(cd -- "$B" && pwd -P)
for file in config.json pw; do
  if [[ ! -r "$RA_DEV_BENCH/$file" ]]; then
    echo "dev: bench: missing readable $file" >&2
    exit 1
  fi
done
AIR="$HOME/.local/opt/go-tools/air"
if [[ ! -x "$AIR" ]]; then
  echo "dev: tool: air is missing at $AIR (S0 tool installation required)" >&2
  exit 1
fi
command -v setsid >/dev/null || { echo 'dev: tool: setsid required' >&2; exit 1; }
mkdir -p .tmp
work=$(mktemp -d "$PWD/.tmp/dev-XXXXXXXX")
air_pid=''
cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$air_pid" ]]; then
    # Air, its build shell and every application generation share this private group.
    kill -TERM -- "-$air_pid" 2>/dev/null || true
    for ((i=0; i<30; i++)); do
      if ! kill -0 -- "-$air_pid" 2>/dev/null; then break; fi
      sleep 0.1
    done
    kill -KILL -- "-$air_pid" 2>/dev/null || true
    wait "$air_pid" 2>/dev/null || true
  fi
  rm -rf -- "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
export RA_DEV_BIN="$work/remoteagents"
setsid "$AIR" -c .air.toml --tmp_dir "$work" &
air_pid=$!
wait "$air_pid"
