#!/bin/zsh
set -euo pipefail

RUN_DIR="${1:-}"
if [[ -z "$RUN_DIR" || ! -d "$RUN_DIR" ]]; then
  echo "usage: $0 <run-dir>" >&2
  exit 2
fi

for pidfile in "$RUN_DIR"/*.pid(N); do
  pid="$(tr -dc '0-9' < "$pidfile")"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
done
