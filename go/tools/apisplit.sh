#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "usage: apisplit.sh <go-v3-api.md> <output-directory>" >&2
  exit 2
fi

mkdir -p -- "$2"
awk -v out="$2" '
  /^## Блок A([[:space:]]|$)/ { block = 1; next }
  block && /^## Блок B([[:space:]]|$)/ { exit }
  block && /^```go[[:space:]]*$/ { code = 1; next }
  block && /^```[[:space:]]*$/ { code = 0; next }
  code && /^\/\/ ===== файл go\/internal\/api\/[[:alnum:]_]+\.go =====$/ {
    if (file != "") close(file)
    name = $0
    sub(/^.*\//, "", name)
    sub(/ =====$/, "", name)
    file = out "/" name
    print "" > file
    next
  }
  code && file != "" { print > file }
  END { if (file == "") exit 1 }
' "$1"
"$(go env GOROOT)/bin/gofmt" -w "$2"
