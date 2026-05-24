#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

ROOT="$(campaign_root)"
STAMP="$(timestamp_utc)"
SRC_RUNTIME="$ROOT/artifacts/runtime"
SRC_DIFFS="$ROOT/artifacts/diffs/variant-pass"
OUT_DIR="${1:-$ROOT/artifacts/shareable/campaign1-$STAMP}"

mkdir -p "$OUT_DIR"/{runtime-summaries,notes,manifests}

if [[ -d "$SRC_RUNTIME" ]]; then
  find "$SRC_RUNTIME" -type f \( \
    -name '*summary.txt' -o \
    -name 'sw_vers.txt' -o \
    -name 'system_profiler-SPSoftwareDataType.txt' -o \
    -name 'csrutil-status.txt' -o \
    -name 'spctl-status.txt' -o \
    -name 'xcodebuild-version.txt' -o \
    -name 'LaunchServices.FeatureFlags*.txt' -o \
    -name 'run-summary.txt' \
  \) -print0 | while IFS= read -r -d '' file; do
    rel="${file#$SRC_RUNTIME/}"
    mkdir -p "$OUT_DIR/runtime-summaries/$(dirname "$rel")"
    cp -p "$file" "$OUT_DIR/runtime-summaries/$rel"
  done
fi

for note in \
  campaign1-current-state.md \
  campaign1-runtime-harness-plan.md \
  campaign1-forcequit-caller-delta.md \
  campaign1-trust-boundary-picture.md
do
  if [[ -f "$SRC_DIFFS/$note" ]]; then
    cp -p "$SRC_DIFFS/$note" "$OUT_DIR/notes/$note"
  fi
done

write_sha256_manifest "$OUT_DIR" "$OUT_DIR/manifests/shareable.sha256"

TAR="$OUT_DIR.tar.gz"
tar -czf "$TAR" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")"

echo "$OUT_DIR"
echo "$TAR"
