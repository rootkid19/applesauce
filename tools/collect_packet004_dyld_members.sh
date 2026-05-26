#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  collect_packet004_dyld_members.sh <label> <dyld_shared_cache_arm64e>

examples:
  tools/collect_packet004_dyld_members.sh 26.5 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
  tools/collect_packet004_dyld_members.sh 26.4 /path/to/26.4/dyld_shared_cache_arm64e

Extracts Packet 004 dyld-cache members. The selected list is FileProvider /
materialization specific, with CloudDocs/iCloud and Storage as watchlist members
only. Prefers ipsw (brew install blacktop/tap/ipsw) for --objc --stubs
enrichment. The dsc_extract_bundle fallback expands the full cache first; expect
disk use. Set APPLESAUCE_KEEP_FULL_EXTRACT=1 to keep fallback full-extract output.
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage

LABEL="$1"
CACHE="$2"
ARTIFACTS="$(artifact_root)"
OUT="$ARTIFACTS/dyld-members-packet004/$LABEL"
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
  # Primary FileProvider framework members.
  "/System/Library/Frameworks/FileProvider.framework/Versions/A/FileProvider"
  "/System/Library/PrivateFrameworks/FileProviderDaemon.framework/Versions/A/FileProviderDaemon"
  "/System/Library/PrivateFrameworks/FileProviderResolver.framework/Versions/A/FileProviderResolver"
  "/System/Library/PrivateFrameworks/FileProviderTelemetry.framework/Versions/A/FileProviderTelemetry"
  "/System/Library/Frameworks/FileProviderUI.framework/Versions/A/FileProviderUI"

  # Promote only if changed.
  "/System/Library/PrivateFrameworks/CloudDocs.framework/Versions/A/CloudDocs"
  "/System/Library/PrivateFrameworks/iCloudDriveCore.framework/Versions/A/iCloudDriveCore"
  "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Versions/A/CloudKitDaemon"

  # Storage sibling watchlist.
  "/System/Library/PrivateFrameworks/StorageManagement.framework/Versions/A/StorageManagement"
  "/System/Library/PrivateFrameworks/StorageManagementService.framework/Versions/A/StorageManagementService"
  "/System/Library/PrivateFrameworks/StorageKit.framework/Versions/A/StorageKit"
  "/System/Library/PrivateFrameworks/StorageUI.framework/Versions/A/StorageUI"
  "/System/Library/PrivateFrameworks/StorageContainersPrivate.framework/Versions/A/StorageContainersPrivate"
)

# Write requested member list before extraction starts.
printf '%s\n' "${MEMBERS[@]}" > "$OUT/metadata/requested-members.txt"

extractor=""
if command -v ipsw >/dev/null 2>&1; then
  extractor="ipsw"
elif command -v dyld_shared_cache_util >/dev/null 2>&1; then
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

Preferred (install via Homebrew):
  brew install blacktop/tap/ipsw

Or install/build one of:
- dyld_shared_cache_util
- dsc_extractor
- /usr/lib/dsc_extractor.bundle wrapper via tools/build_dsc_extractor_bundle_wrapper.sh
EOF
  cat "$OUT/metadata/extraction-blocked.txt"
  exit 1
fi

# Write extractor identity metadata.
{
  echo "extractor=$extractor"
  if [[ "$extractor" == "ipsw" ]]; then
    ipsw version 2>/dev/null || echo "version=unknown"
  else
    echo "version=n/a"
  fi
  echo "cache=$CACHE"
} > "$OUT/metadata/extractor.txt"

print_member_list() {
  case "$extractor" in
    ipsw)
      ipsw dyld info --dylibs --no-color "$CACHE" 2>/dev/null
      ;;
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
    ipsw)
      ipsw dyld extract --objc --stubs --force --no-color -o "$OUT/members" "$CACHE" "$member" >/dev/null 2>&1
      ;;
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
  local safe="${rel//\//__}"

  if [[ ! -f "$src" ]]; then
    src="$(find "$base" -type f -path "*/$rel" -print -quit 2>/dev/null || true)"
  fi

  if [[ -z "$src" || ! -f "$src" ]]; then
    echo "$member" >> "$OUT/metadata/selected-missing.txt"
    return 1
  fi

  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  file "$dst" > "$OUT/metadata/$safe.file.txt" 2>&1 || true
  shasum -a 256 "$dst" > "$OUT/metadata/$safe.sha256" 2>&1 || true
  strings -a "$dst" > "$OUT/metadata/$safe.strings.txt" 2>&1 || true
  nm -m "$dst" > "$OUT/metadata/$safe.nm-m.txt" 2>&1 || true
  otool -L "$dst" > "$OUT/metadata/$safe.otool-L.txt" 2>&1 || true
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

  if [[ "${APPLESAUCE_KEEP_FULL_EXTRACT:-0}" != "1" ]]; then
    echo "[*] removing temporary full-extract output"
    rm -rf "$FULL"
    echo "removed; set APPLESAUCE_KEEP_FULL_EXTRACT=1 to keep it" > "$OUT/metadata/full-extract.removed.txt"
  fi
else
  echo "[*] extractor: $extractor"
  for member in "${MEMBERS[@]}"; do
    echo "[*] extracting $member"
    if extract_member "$member"; then
      echo "$member" >> "$OUT/metadata/extracted.txt"
      copy_selected_member "$OUT/members" "$member" || true
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
