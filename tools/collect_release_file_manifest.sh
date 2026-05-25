#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  collect_release_file_manifest.sh <label> [root]

examples:
  tools/collect_release_file_manifest.sh 26.5 /
  tools/collect_release_file_manifest.sh 26.4 /Volumes/Tahoe-26.4

Builds a broad system-code/config file manifest for first-mile changed-artifact
selection. It is intentionally broader than packet-specific collectors.

Set APPLESAUCE_MANIFEST_HASH=0 to skip sha256 hashing and collect metadata only.
EOF
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage

LABEL="$1"
ROOT="${2:-/}"
ARTIFACTS="$(artifact_root)"
OUT="$ARTIFACTS/release-manifests/$LABEL"
HASH_MODE="${APPLESAUCE_MANIFEST_HASH:-1}"
AWK_BIN="${APPLESAUCE_AWK:-/usr/bin/awk}"
FIND_BIN="${APPLESAUCE_FIND:-/usr/bin/find}"
READLINK_BIN="${APPLESAUCE_READLINK:-/usr/bin/readlink}"
SHASUM_BIN="${APPLESAUCE_SHASUM:-/usr/bin/shasum}"
SORT_BIN="${APPLESAUCE_SORT:-/usr/bin/sort}"
STAT_BIN="${APPLESAUCE_STAT:-/usr/bin/stat}"

if [[ ! -d "$ROOT" ]]; then
  echo "root not found: $ROOT" >&2
  exit 2
fi

ROOT="$(cd "$ROOT" && pwd)"
mkdir -p "$OUT"/metadata

echo "[*] label: $LABEL"
echo "[*] root: $ROOT"
echo "[*] out: $OUT"
echo "[*] hash mode: $HASH_MODE"

{
  echo "label=$LABEL"
  echo "root=$ROOT"
  echo "hash_mode=$HASH_MODE"
  date -u +"date_utc=%Y-%m-%dT%H:%M:%SZ"
  if [[ "$ROOT" == "/" ]]; then
    sw_vers 2>/dev/null || true
  elif [[ -f "$ROOT/System/Library/CoreServices/SystemVersion.plist" ]]; then
    plutil -p "$ROOT/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null || true
  fi
} > "$OUT/metadata/manifest-context.txt" 2>&1

ROOTS=(
  "/System/Library/LaunchDaemons"
  "/System/Library/LaunchAgents"
  "/System/Library/Sandbox"
  "/System/Library/FeatureFlags"
  "/System/Library/Preferences"
  "/System/Library/CoreServices"
  "/System/Library/Frameworks"
  "/System/Library/PrivateFrameworks"
  "/System/Library/ExtensionKit/Extensions"
  "/usr/bin"
  "/usr/sbin"
  "/usr/lib"
  "/usr/libexec"
)

root_join() {
  local rel="$1"
  rel="${rel#/}"
  if [[ "$ROOT" == "/" ]]; then
    echo "/$rel"
  else
    echo "$ROOT/$rel"
  fi
}

rel_path() {
  local path="$1"
  if [[ "$ROOT" == "/" ]]; then
    echo "${path#/}"
  else
    echo "${path#$ROOT/}"
  fi
}

file_sha() {
  local path="$1"
  local digest
  if [[ "$HASH_MODE" == "0" ]]; then
    echo "-"
    return
  fi
  digest="$("$SHASUM_BIN" -a 256 "$path" 2>/dev/null || true)"
  if [[ -z "$digest" ]]; then
    echo "-"
  else
    echo "${digest%% *}"
  fi
}

manifest="$OUT/manifest.tsv"
: > "$OUT/metadata/missing-roots.txt"
: > "$OUT/metadata/find-errors.txt"

{
  printf "path\ttype\tsize\tmtime_epoch\tsha256\tsymlink_target\n"
  for rel_root in "${ROOTS[@]}"; do
    abs_root="$(root_join "$rel_root")"
    if [[ ! -d "$abs_root" ]]; then
      echo "$rel_root" >> "$OUT/metadata/missing-roots.txt"
      continue
    fi

    "$FIND_BIN" "$abs_root" \( -type f -o -type l \) -print 2>>"$OUT/metadata/find-errors.txt" | while IFS= read -r path; do
      rel="$(rel_path "$path")"
      if [[ -L "$path" ]]; then
        target="$("$READLINK_BIN" "$path" 2>/dev/null || true)"
        printf "%s\tsymlink\t-\t-\t-\t%s\n" "$rel" "$target"
      elif [[ -f "$path" ]]; then
        size="$("$STAT_BIN" -f "%z" "$path" 2>/dev/null || echo "-")"
        mtime="$("$STAT_BIN" -f "%m" "$path" 2>/dev/null || echo "-")"
        sha="$(file_sha "$path")"
        printf "%s\tfile\t%s\t%s\t%s\t-\n" "$rel" "$size" "$mtime" "$sha"
      fi
    done
  done
} | LC_ALL=C "$SORT_BIN" -u > "$manifest"

"$AWK_BIN" -F '\t' 'NR > 1 { c[$2]++ } END { for (k in c) printf("%s\t%d\n", k, c[k]) }' "$manifest" | "$SORT_BIN" > "$OUT/metadata/type-counts.tsv"

echo "$OUT"
