#!/bin/zsh
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$HARNESS_DIR/build"
SRC="$HARNESS_DIR/src/packet004_import_move_probe.m"
OUT="$BUILD_DIR/packet004_import_move_probe"

mkdir -p "$BUILD_DIR"

clang \
  -fobjc-arc \
  -fblocks \
  -O0 \
  -g \
  -Wall \
  -Wextra \
  -framework Foundation \
  "$SRC" \
  -o "$OUT"

echo "$OUT"
