#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  diff_release_file_manifests.sh <baseline-label> <patched-label>

example:
  tools/diff_release_file_manifests.sh 26.4 26.5

Compares broad release file manifests produced by
collect_release_file_manifest.sh and writes added/removed/changed/stable files.
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage

BASE_LABEL="$1"
PATCH_LABEL="$2"
ARTIFACTS="$(artifact_root)"
BASE="$ARTIFACTS/release-manifests/$BASE_LABEL/manifest.tsv"
PATCH="$ARTIFACTS/release-manifests/$PATCH_LABEL/manifest.tsv"
OUT="$ARTIFACTS/release-manifests/diff-$BASE_LABEL-vs-$PATCH_LABEL"
AWK_BIN="${APPLESAUCE_AWK:-/usr/bin/awk}"
SORT_BIN="${APPLESAUCE_SORT:-/usr/bin/sort}"

if [[ ! -f "$BASE" ]]; then
  echo "missing baseline manifest: $BASE" >&2
  exit 2
fi

if [[ ! -f "$PATCH" ]]; then
  echo "missing patched manifest: $PATCH" >&2
  exit 2
fi

mkdir -p "$OUT"

echo "[*] baseline: $BASE_LABEL"
echo "[*] patched: $PATCH_LABEL"
echo "[*] out: $OUT"

"$AWK_BIN" -F '\t' '
  FNR == 1 { next }
  NR == FNR {
    b[$1] = $0
    b_sha[$1] = $5
    b_size[$1] = $3
    b_type[$1] = $2
    seen[$1] = 1
    next
  }
  {
    p[$1] = $0
    p_sha[$1] = $5
    p_size[$1] = $3
    p_type[$1] = $2
    seen[$1] = 1
  }
  END {
    print "path\tresult\tbaseline_type\tpatched_type\tbaseline_size\tpatched_size\tbaseline_sha256\tpatched_sha256"
    for (path in seen) {
      if (!(path in b)) {
        print path "\tadded\t-\t" p_type[path] "\t-\t" p_size[path] "\t-\t" p_sha[path]
      } else if (!(path in p)) {
        print path "\tremoved\t" b_type[path] "\t-\t" b_size[path] "\t-\t" b_sha[path] "\t-"
      } else if (b_sha[path] != p_sha[path] || b_size[path] != p_size[path] || b_type[path] != p_type[path]) {
        print path "\tchanged\t" b_type[path] "\t" p_type[path] "\t" b_size[path] "\t" p_size[path] "\t" b_sha[path] "\t" p_sha[path]
      } else {
        print path "\tstable\t" b_type[path] "\t" p_type[path] "\t" b_size[path] "\t" p_size[path] "\t" b_sha[path] "\t" p_sha[path]
      }
    }
  }
' "$BASE" "$PATCH" | LC_ALL=C "$SORT_BIN" > "$OUT/manifest-diff.tsv"

"$AWK_BIN" -F '\t' 'NR > 1 { c[$2]++ } END { for (k in c) printf("- %s: %d\n", k, c[k]) }' "$OUT/manifest-diff.tsv" | "$SORT_BIN" > "$OUT/summary.md"
"$AWK_BIN" -F '\t' 'NR > 1 && $2 != "stable" { print }' "$OUT/manifest-diff.tsv" > "$OUT/changed-added-removed.tsv"

echo "$OUT"
