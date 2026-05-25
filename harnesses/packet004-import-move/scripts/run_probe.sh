#!/bin/zsh
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HARNESS_DIR/build/packet004_import_move_probe"

if [[ ! -x "$BIN" ]]; then
  "$HARNESS_DIR/scripts/build.sh" >/dev/null
fi

exec "$BIN" "$@"
