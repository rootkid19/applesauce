#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

ARTIFACTS="$(artifact_root)"
STAMP="$(timestamp_utc)"
OUT="${1:-$ARTIFACTS/runtime/host-state/$(safe_sw_build_slug)-$STAMP}"

mkdir -p "$OUT"

sw_vers > "$OUT/sw_vers.txt" 2>&1 || true
system_profiler SPSoftwareDataType > "$OUT/system_profiler-SPSoftwareDataType.txt" 2>&1 || true
csrutil status > "$OUT/csrutil-status.txt" 2>&1 || true
spctl --status > "$OUT/spctl-status.txt" 2>&1 || true
xcodebuild -version > "$OUT/xcodebuild-version.txt" 2>&1 || true
uname -a > "$OUT/uname.txt" 2>&1 || true
mount > "$OUT/mount.txt" 2>&1 || true
df -h > "$OUT/df-h.txt" 2>&1 || true
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$OUT/date-utc.txt"

PLIST="/Library/Preferences/FeatureFlags/Domain/LaunchServices.plist"
{
  echo "path=$PLIST"
  if [[ -e "$PLIST" ]]; then
    ls -laeO@ "$PLIST" || true
    xattr -lr "$PLIST" || true
    shasum -a 256 "$PLIST" || true
    plutil -p "$PLIST" || true
  else
    echo "missing"
  fi
} > "$OUT/LaunchServices.FeatureFlags.state.txt" 2>&1

echo "$OUT"
