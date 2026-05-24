#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  collect_campaign1_dyld_members.sh <label> <dyld_shared_cache_arm64e>

example:
  tools/collect_campaign1_dyld_members.sh 26.3 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e

Writes extracted members under the local campaign artifact tree. Do not commit
the output directory to GitHub.

If dyld_shared_cache_util is unavailable, this script can build and use the
local /usr/lib/dsc_extractor.bundle wrapper. That fallback extracts the full
cache first, then copies the selected members.
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage

LABEL="$1"
CACHE="$2"
ARTIFACTS="$(artifact_root)"
OUT="$ARTIFACTS/dyld-members/$LABEL"
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$CACHE" ]]; then
  echo "cache not found: $CACHE" >&2
  exit 2
fi

mkdir -p "$OUT"/{members,selected,metadata}

echo "[*] label: $LABEL"
echo "[*] cache: $CACHE"
echo "[*] out: $OUT"

shasum -a 256 "$CACHE" > "$OUT/metadata/dyld_shared_cache_arm64e.sha256" 2>&1 || true
file "$CACHE" > "$OUT/metadata/dyld_shared_cache_arm64e.file.txt" 2>&1 || true
ls -laeO@ "$CACHE"* > "$OUT/metadata/cache-siblings-ls.txt" 2>&1 || true

MEMBERS=(
  "/usr/lib/libLaunchServicesSupport.dylib"
  "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/LaunchServices"
  "/System/Library/PrivateFrameworks/CoreServicesInternal.framework/Versions/A/CoreServicesInternal"
  "/System/Library/PrivateFrameworks/BackgroundTaskManagement.framework/Versions/A/BackgroundTaskManagement"
  "/System/Library/Frameworks/ServiceManagement.framework/Versions/A/ServiceManagement"
)

extractor=""
if command -v dyld_shared_cache_util >/dev/null 2>&1; then
  extractor="dyld_shared_cache_util"
elif command -v dsc_extractor >/dev/null 2>&1; then
  extractor="dsc_extractor"
elif [[ -x "$TOOLS_DIR/dsc_extract_bundle" || -f /usr/lib/dsc_extractor.bundle ]]; then
  if [[ ! -x "$TOOLS_DIR/dsc_extract_bundle" ]]; then
    "$TOOLS_DIR/build_dsc_extractor_bundle_wrapper.sh" > "$OUT/metadata/build-dsc-wrapper.stdout.txt" 2>"$OUT/metadata/build-dsc-wrapper.stderr.txt"
  fi
  extractor="dsc_extract_bundle"
fi

if [[ -z "$extractor" ]]; then
  cat > "$OUT/metadata/extraction-blocked.txt" <<'EOF'
No supported extractor found in PATH.

Install or build one of:
- dyld_shared_cache_util
- dsc_extractor
- /usr/lib/dsc_extractor.bundle wrapper via tools/build_dsc_extractor_bundle_wrapper.sh

Then rerun this script.
EOF
  cat "$OUT/metadata/extraction-blocked.txt"
  exit 1
fi

print_member_list() {
  case "$extractor" in
    dyld_shared_cache_util)
      dyld_shared_cache_util -list "$CACHE"
      ;;
    dsc_extractor)
      dsc_extractor --list "$CACHE"
      ;;
    dsc_extract_bundle)
      echo "local dsc_extract_bundle fallback does not support listing"
      ;;
  esac
}

extract_member() {
  local member="$1"
  case "$extractor" in
    dyld_shared_cache_util)
      dyld_shared_cache_util -extract "$member" "$CACHE" "$OUT/members" >/dev/null 2>&1
      ;;
    dsc_extractor)
      dsc_extractor --extract "$member" "$CACHE" "$OUT/members" >/dev/null 2>&1
      ;;
    dsc_extract_bundle)
      return 3
      ;;
  esac
}

print_member_list > "$OUT/metadata/cache-members.txt" 2>"$OUT/metadata/cache-members.stderr.txt" || true

copy_selected_member() {
  local base="$1"
  local member="$2"
  local rel="${member#/}"
  local src="$base/$rel"
  local dst="$OUT/selected/$rel"

  if [[ ! -f "$src" ]]; then
    src="$(find "$base" -type f -path "*/$rel" -print -quit 2>/dev/null || true)"
  fi

  if [[ -z "$src" || ! -f "$src" ]]; then
    echo "$member" >> "$OUT/metadata/selected-missing.txt"
    return 1
  fi

  mkdir -p "$(dirname "$dst")"
  cp -p "$src" "$dst"
  file "$dst" > "$OUT/metadata/$(basename "$member").file.txt" 2>&1 || true
  shasum -a 256 "$dst" > "$OUT/metadata/$(basename "$member").sha256" 2>&1 || true
  echo "$member" >> "$OUT/metadata/selected.txt"
}

if [[ "$extractor" == "dsc_extract_bundle" ]]; then
  FULL="$OUT/full-extract"
  mkdir -p "$FULL"
  echo "[*] extractor: local dsc_extract_bundle full-cache fallback"
  "$TOOLS_DIR/dsc_extract_bundle" "$CACHE" "$FULL" > "$OUT/metadata/full-extract.stdout.txt" 2>"$OUT/metadata/full-extract.stderr.txt"

  for member in "${MEMBERS[@]}"; do
    echo "[*] selecting $member"
    copy_selected_member "$FULL" "$member" || true
  done
else
  echo "[*] extractor: $extractor"
  for member in "${MEMBERS[@]}"; do
    echo "[*] extracting $member"
    if extract_member "$member"; then
      echo "$member" >> "$OUT/metadata/extracted.txt"
    else
      echo "$member" >> "$OUT/metadata/missing-or-failed.txt"
    fi
  done
fi

find "$OUT/members" -type f -print > "$OUT/metadata/extracted-files.txt" 2>&1 || true
find "$OUT/selected" -type f -print > "$OUT/metadata/selected-files.txt" 2>&1 || true
write_sha256_manifest "$OUT/members" "$OUT/metadata/extracted-files.sha256"
write_sha256_manifest "$OUT/selected" "$OUT/metadata/selected-files.sha256"

echo "$OUT"
