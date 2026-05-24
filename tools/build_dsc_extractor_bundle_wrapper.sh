#!/bin/zsh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/dsc_extract_bundle"

if [[ ! -f /usr/lib/dsc_extractor.bundle ]]; then
  echo "missing /usr/lib/dsc_extractor.bundle" >&2
  exit 2
fi

if ! command -v clang >/dev/null 2>&1; then
  echo "missing clang" >&2
  exit 2
fi

clang -fblocks -O2 -Wall -Wextra -o "$OUT" "$HERE/dsc_extract_bundle.c"
echo "$OUT"
