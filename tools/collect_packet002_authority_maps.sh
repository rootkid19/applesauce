#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  collect_packet002_authority_maps.sh <label>

examples:
  tools/collect_packet002_authority_maps.sh 26.5
  tools/collect_packet002_authority_maps.sh 26.4

Runs reverse_authority_map.sh on every Mach-O binary previously collected
under artifacts/packet002-accounts-privacy/<label>/standalone/. Output goes
to artifacts/packet002-accounts-privacy/<label>/analysis/authority-maps/.

Run after collect_packet002_accounts_artifacts.sh has completed for the label.
This script is non-destructive: existing authority-map subdirectories are
overwritten per binary.
EOF
  exit 2
}

[[ $# -eq 1 ]] || usage

LABEL="$1"
ARTIFACTS="$(artifact_root)"
STANDALONE="$ARTIFACTS/packet002-accounts-privacy/$LABEL/standalone"
MAPROOT="$ARTIFACTS/packet002-accounts-privacy/$LABEL/analysis/authority-maps"
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -d "$STANDALONE" ]]; then
  echo "standalone directory not found: $STANDALONE" >&2
  echo "Run collect_packet002_accounts_artifacts.sh $LABEL first." >&2
  exit 2
fi

mkdir -p "$MAPROOT"

echo "[*] label:      $LABEL"
echo "[*] standalone: $STANDALONE"
echo "[*] maps out:   $MAPROOT"

count=0
skipped=0

while IFS= read -r -d '' bin; do
  if file "$bin" 2>/dev/null | grep -qE 'Mach-O|dylib'; then
    rel="${bin#$STANDALONE/}"
    safe="${rel//\//__}"
    outdir="$MAPROOT/$safe"
    echo "[*] mapping: $rel"
    "$TOOLS_DIR/reverse_authority_map.sh" "$bin" "$outdir" 2>&1 | grep -v '^\[done\]' || true
    (( count++ )) || true
  else
    (( skipped++ )) || true
  fi
done < <(find "$STANDALONE" -type f -print0 2>/dev/null)

echo "[*] mapped: $count binaries, skipped non-Mach-O: $skipped"
echo "$MAPROOT"
