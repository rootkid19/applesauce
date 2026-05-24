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
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage

LABEL="$1"
CACHE="$2"
ROOT="$(campaign_root)"
OUT="$ROOT/artifacts/dyld-members/$LABEL"

if [[ ! -f "$CACHE" ]]; then
  echo "cache not found: $CACHE" >&2
  exit 2
fi

mkdir -p "$OUT"/{members,metadata}

echo "[*] label: $LABEL"
echo "[*] cache: $CACHE"
echo "[*] out: $OUT"

shasum -a 256 "$CACHE" > "$OUT/metadata/dyld_shared_cache_arm64e.sha256" 2>&1 || true
file "$CACHE" > "$OUT/metadata/dyld_shared_cache_arm64e.file.txt" 2>&1 || true
ls -laeO@ "$CACHE"* > "$OUT/metadata/cache-siblings-ls.txt" 2>&1 || true

MEMBERS=(
  "/usr/lib/libLaunchServicesSupport.dylib"
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/A/LaunchServices"
  "/System/Library/PrivateFrameworks/CoreServicesInternal.framework/Versions/A/CoreServicesInternal"
  "/System/Library/PrivateFrameworks/BackgroundTaskManagement.framework/Versions/A/BackgroundTaskManagement"
  "/System/Library/Frameworks/ServiceManagement.framework/Versions/A/ServiceManagement"
)

extractor=""
if command -v dyld_shared_cache_util >/dev/null 2>&1; then
  extractor="dyld_shared_cache_util"
elif command -v dsc_extractor >/dev/null 2>&1; then
  extractor="dsc_extractor"
fi

if [[ -z "$extractor" ]]; then
  cat > "$OUT/metadata/extraction-blocked.txt" <<'EOF'
No supported extractor found in PATH.

Install or build one of:
- dyld_shared_cache_util
- dsc_extractor

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
  esac
}

print_member_list > "$OUT/metadata/cache-members.txt" 2>"$OUT/metadata/cache-members.stderr.txt" || true

for member in "${MEMBERS[@]}"; do
  safe="${member#/}"
  safe="${safe//\//__}"
  echo "[*] extracting $member"
  if extract_member "$member"; then
    echo "$member" >> "$OUT/metadata/extracted.txt"
  else
    echo "$member" >> "$OUT/metadata/missing-or-failed.txt"
  fi
done

find "$OUT/members" -type f -print > "$OUT/metadata/extracted-files.txt" 2>&1 || true
write_sha256_manifest "$OUT/members" "$OUT/metadata/extracted-files.sha256"

echo "$OUT"
