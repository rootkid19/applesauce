#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  diff_packet006_binary_truth.sh <baseline-label> <patched-label>

example:
  tools/diff_packet006_binary_truth.sh 26.4 26.5

Compares Packet 006 collection outputs and writes a deterministic byte-level
matrix under artifacts/packet006-sandbox-protected-data/diff-<old>-vs-<new>.
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage

BASE_LABEL="$1"
PATCH_LABEL="$2"
ARTIFACTS="$(artifact_root)"
BASE_ROOT="$ARTIFACTS/packet006-sandbox-protected-data/$BASE_LABEL"
PATCH_ROOT="$ARTIFACTS/packet006-sandbox-protected-data/$PATCH_LABEL"
BASE_DYLD="$ARTIFACTS/dyld-members-packet006/$BASE_LABEL/selected"
PATCH_DYLD="$ARTIFACTS/dyld-members-packet006/$PATCH_LABEL/selected"
OUT="$ARTIFACTS/packet006-sandbox-protected-data/diff-$BASE_LABEL-vs-$PATCH_LABEL"

if [[ ! -d "$BASE_ROOT" ]]; then
  echo "missing baseline artifacts: $BASE_ROOT" >&2
  exit 2
fi

if [[ ! -d "$PATCH_ROOT" ]]; then
  echo "missing patched artifacts: $PATCH_ROOT" >&2
  exit 2
fi

mkdir -p "$OUT"/{metadata,trees}

echo "[*] baseline: $BASE_LABEL"
echo "[*] patched: $PATCH_LABEL"
echo "[*] out: $OUT"

{
  echo "baseline=$BASE_LABEL"
  echo "patched=$PATCH_LABEL"
  echo "baseline_root=$BASE_ROOT"
  echo "patched_root=$PATCH_ROOT"
  echo "baseline_dyld=$BASE_DYLD"
  echo "patched_dyld=$PATCH_DYLD"
  date -u +"date_utc=%Y-%m-%dT%H:%M:%SZ"
} > "$OUT/metadata/diff-context.txt"

sha_or_dash() {
  local path="$1"
  if [[ -f "$path" ]]; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    echo "-"
  fi
}

compare_tree() {
  local category="$1"
  local left="$2"
  local right="$3"
  local out="$OUT/trees/$category.tsv"
  local left_list="$OUT/metadata/$category.$BASE_LABEL.files"
  local right_list="$OUT/metadata/$category.$PATCH_LABEL.files"
  local all_list="$OUT/metadata/$category.all-files"

  : > "$left_list"
  : > "$right_list"

  if [[ -d "$left" ]]; then
    (cd "$left" && find . -type f -print | sed 's#^\./##' | sort) > "$left_list"
  fi

  if [[ -d "$right" ]]; then
    (cd "$right" && find . -type f -print | sed 's#^\./##' | sort) > "$right_list"
  fi

  sort -u "$left_list" "$right_list" > "$all_list"

  {
    printf "category\tpath\tresult\tbaseline_sha256\tpatched_sha256\n"
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      local left_path="$left/$rel"
      local right_path="$right/$rel"
      local result

      if [[ -f "$left_path" && -f "$right_path" ]]; then
        if cmp -s "$left_path" "$right_path"; then
          result="identical"
        else
          result="changed"
        fi
      elif [[ -f "$left_path" ]]; then
        result="removed"
      else
        result="added"
      fi

      printf "%s\t%s\t%s\t%s\t%s\n" "$category" "$rel" "$result" "$(sha_or_dash "$left_path")" "$(sha_or_dash "$right_path")"
    done < "$all_list"
  } > "$out"
}

compare_tree standalone "$BASE_ROOT/standalone" "$PATCH_ROOT/standalone"
compare_tree profiles "$BASE_ROOT/profiles" "$PATCH_ROOT/profiles"
compare_tree protected-cloud-storage-identities "$BASE_ROOT/protected-cloud-storage-identities" "$PATCH_ROOT/protected-cloud-storage-identities"

if [[ -d "$BASE_DYLD" || -d "$PATCH_DYLD" ]]; then
  compare_tree dyld-selected "$BASE_DYLD" "$PATCH_DYLD"
else
  echo "dyld selected directories missing for one or both labels" > "$OUT/metadata/dyld-selected-skipped.txt"
fi

{
  echo "# Packet 006 Binary Truth Summary"
  echo
  echo "Baseline: $BASE_LABEL"
  echo "Patched: $PATCH_LABEL"
  echo
  for tsv in "$OUT"/trees/*.tsv; do
    [[ -f "$tsv" ]] || continue
    name="$(basename "$tsv" .tsv)"
    echo "## $name"
    awk -F '\t' 'NR > 1 { c[$3]++ } END { for (k in c) printf("- %s: %d\n", k, c[k]) }' "$tsv" | sort
    echo
  done
} > "$OUT/summary.md"

echo "$OUT"
