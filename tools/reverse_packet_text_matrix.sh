#!/bin/zsh
set -euo pipefail
unsetopt verbose xtrace

# reverse_packet_text_matrix.sh (v2)
#
# Given two collected artifact roots, emit a deterministic TSV/Markdown matrix
# of executable Mach-O files with:
#   - whole-file SHA-256 comparison
#   - best-arch selection (arm64e > arm64 > first available)
#   - __TEXT,__text offset, size, and SHA-256 of exact text bytes
#   - import count, string count
#   - symlink/path-hardening signal counts (strings + imports)
#   - dyld-selected category support (standalone + selected/)
#
# Designed for Apple patch-diff research: separates rebase/signature drift from
# actual __text changes by hashing exact code-section bytes.
#
# usage:
#   reverse_packet_text_matrix.sh [options] <baseline-root> <patched-root> [outdir]
#   reverse_packet_text_matrix.sh --regression-test <root>
#
# options:
#   --changed-only      Output only rows with whole-file or __text changes
#   --signals-only      Output only rows with symlink-signal hits
#   --format tsv|jsonl  Output format (default: tsv)
#
# examples:
#   reverse_packet_text_matrix.sh artifacts/.../26.4 artifacts/.../26.5
#   reverse_packet_text_matrix.sh --changed-only --signals-only \
#     artifacts/.../26.4 artifacts/.../26.5
#   reverse_packet_text_matrix.sh --regression-test artifacts/.../26.5
#
# Output:
#   matrix.tsv       - primary matrix (filtered if options used)
#   full-matrix.tsv  - always the complete unfiltered matrix
#   summary.md       - human-readable Markdown summary
#
# Deterministic requirements:
#   - lipo, otool, file, strings, cmp, shasum, python3, awk

source "$(cd "$(dirname "${(%):-%x}")" && pwd)/common.sh"
source "$(cd "$(dirname "${(%):-%x}")" && pwd)/common_reverse.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  reverse_packet_text_matrix.sh [options] <baseline-root> <patched-root> [outdir]
  reverse_packet_text_matrix.sh --regression-test <root>

options:
  --changed-only      Output only rows with whole-file or __text changes
  --signals-only      Output only rows with symlink-signal hits
  --format tsv|jsonl  Output format (default: tsv)

examples:
  reverse_packet_text_matrix.sh artifacts/packet007-syncservices-contacts/26.4 \
                                 artifacts/packet007-syncservices-contacts/26.5

  reverse_packet_text_matrix.sh --changed-only --format jsonl \
                                 artifacts/packet007-syncservices-contacts/26.4 \
                                 artifacts/packet007-syncservices-contacts/26.5

  reverse_packet_text_matrix.sh --regression-test artifacts/packet007-syncservices-contacts/26.5
EOF
  exit 2
}

# ---------------------------------------------------------------------------
# Option parsing
# ---------------------------------------------------------------------------

CHANGED_ONLY_ARR=()
SIGNALS_ONLY_ARR=()
FORMAT_ARR=()
REGRESSION_TEST_ARR=()

zparseopts -D -E -- \
  -changed-only=CHANGED_ONLY_ARR \
  -signals-only=SIGNALS_ONLY_ARR \
  -format:=FORMAT_ARR \
  -regression-test=REGRESSION_TEST_ARR

CHANGED_ONLY="${#CHANGED_ONLY_ARR}"
SIGNALS_ONLY="${#SIGNALS_ONLY_ARR}"
REGRESSION_TEST="${#REGRESSION_TEST_ARR}"
FORMAT="tsv"
if [[ "${#FORMAT_ARR}" -gt 0 ]]; then
  FORMAT="${FORMAT_ARR[2]}"
fi

if [[ "$FORMAT" != "tsv" && "$FORMAT" != "jsonl" ]]; then
  echo "Invalid format: $FORMAT (expected tsv or jsonl)" >&2
  usage
fi

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

if [[ "$REGRESSION_TEST" -eq 1 ]]; then
  [[ $# -eq 1 ]] || usage
  BASE_ROOT="${1:A}"
  PATCH_ROOT="${1:A}"
  OUT="$(mktemp -d)"
  REGRESSION_LABEL="${1:t}"
else
  [[ $# -ge 2 && $# -le 3 ]] || usage
  BASE_ROOT="${1:A}"
  PATCH_ROOT="${2:A}"
  if [[ $# -eq 3 ]]; then
    OUT="${3:A}"
  else
    OUT="$(artifact_root)/packet007-syncservices-contacts/text-matrix-$(basename "$BASE_ROOT")-vs-$(basename "$PATCH_ROOT")"
  fi
fi

[[ -d "$BASE_ROOT" ]] || reverse_die "baseline root not found: $BASE_ROOT"
[[ -d "$PATCH_ROOT" ]] || reverse_die "patched root not found: $PATCH_ROOT"

mkdir -p "$OUT"

TMPDIR="$(mktemp -d)"
trap "rm -rf '$TMPDIR'" EXIT

SYMLINK_PATTERN='symlink|readlink|realpath|lstat|fstatat|openat|getattrlist|faccessat|O_NOFOLLOW|URLByResolvingSymlinksInPath|standardizedURL|destinationOfSymbolicLink|isSymbolicLink|ResolvingSymlinksInPath'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_macho() {
  file "$1" 2>/dev/null | grep -q "Mach-O"
}

get_thin_for_arch() {
  local bin="$1"
  local want="$2"
  local out="$3"

  local archs=""
  if command -v lipo >/dev/null 2>&1; then
    archs="$(lipo -archs "$bin" 2>/dev/null || true)"
  fi
  if [[ -z "$archs" ]]; then
    archs="$(file "$bin" 2>/dev/null | sed -n 's/.*Mach-O .* \(arm64e\|arm64\|x86_64\).*/\1/p' | head -1)"
  fi

  local has_want=0
  for a in ${(s: :)archs}; do
    [[ "$a" == "$want" ]] && has_want=1
  done

  if [[ "$has_want" -eq 1 ]]; then
    if [[ "$archs" == "$want" ]]; then
      cp "$bin" "$out"
      return 0
    fi
    lipo -thin "$want" -output "$out" "$bin" 2>/dev/null && return 0
  fi

  local first="$(echo "$archs" | awk '{print $1}')"
  if [[ -n "$first" ]]; then
    if [[ "$archs" == "$first" ]]; then
      cp "$bin" "$out"
      return 0
    fi
    lipo -thin "$first" -output "$out" "$bin" 2>/dev/null && return 0
  fi

  return 1
}

get_text_section() {
  local thin="$1"
  otool -l "$thin" 2>/dev/null | awk '
    /^Section$/ { sec=1; sn=""; sg=""; off=""; sz="" }
    sec && /sectname / { sn=$2 }
    sec && /segname /  { sg=$2 }
    sec && /offset /   { off=$2 }
    sec && /size /     { sz=$2 }
    sec && sn=="__text" && sg=="__TEXT" && off!="" && sz!="" && !done {
      print off, sz
      done=1
    }
  '
}

hash_bytes() {
  local bin="$1"
  local offset="$2"
  local count="$3"
  python3 -c '
import sys
with open(sys.argv[1], "rb") as f:
    f.seek(int(sys.argv[2], 0))
    data = f.read(int(sys.argv[3], 0))
    sys.stdout.buffer.write(data)
' "$bin" "$offset" "$count" 2>/dev/null | shasum -a 256 2>/dev/null | awk '{print $1}'
}

count_imports() {
  local thin="$1"
  otool -Iv "$thin" 2>/dev/null | awk 'NR>3 && $1 ~ /^0x[0-9a-fA-F]+$/ {c++} END {print c+0}'
}

count_strings() {
  local thin="$1"
  strings "$thin" 2>/dev/null | wc -l | tr -d ' '
}

symlink_signals() {
  local thin="$1"
  local str_count import_count
  str_count="$(strings "$thin" 2>/dev/null | grep -ciE "$SYMLINK_PATTERN" || true)"
  import_count="$(otool -Iv "$thin" 2>/dev/null | grep -ciE "$SYMLINK_PATTERN" || true)"
  echo "$(( str_count + import_count ))"
}

# ---------------------------------------------------------------------------
# Discovery: find Mach-O files under standalone/ and selected/ in both roots
# ---------------------------------------------------------------------------

BASE_MACHOS="$TMPDIR/base.machos.txt"
PATCH_MACHOS="$TMPDIR/patch.machos.txt"
ALL_MACHOS="$TMPDIR/all.machos.txt"

: > "$BASE_MACHOS"
: > "$PATCH_MACHOS"

discover_machos() {
  local root="$1"
  local out="$2"
  local found_structured=0
  {
    for subdir in standalone selected; do
      if [[ -d "$root/$subdir" ]]; then
        found_structured=1
        (cd "$root/$subdir" && find . -type f -print) | while IFS= read -r rel; do
          rel="${rel#./}"
          [[ -n "$rel" ]] || continue
          # Skip dyld .a2s sidecar files
          if [[ "$rel" == *.a2s ]]; then
            continue
          fi
          if is_macho "$root/$subdir/$rel"; then
            printf "%s\t%s\n" "$subdir" "$rel"
          fi
        done
      fi
    done
    if [[ "$found_structured" -eq 0 ]]; then
      (cd "$root" && find . -type f -print) | while IFS= read -r rel; do
        rel="${rel#./}"
        [[ -n "$rel" ]] || continue
        if [[ "$rel" == *.a2s ]]; then
          continue
        fi
        if is_macho "$root/$rel"; then
          printf "%s\t%s\n" "unknown-root" "$rel"
        fi
      done
    fi
  } > "$out"
}

discover_machos "$BASE_ROOT" "$BASE_MACHOS"
discover_machos "$PATCH_ROOT" "$PATCH_MACHOS"

sort -t$'\t' -k1,2 -u "$BASE_MACHOS" "$PATCH_MACHOS" > "$ALL_MACHOS"

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

FULL_TSV="$OUT/full-matrix.tsv"
{
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "rel_path" "category" "baseline_present" "patched_present" "whole_file_same" \
    "arch" "text_offset" "text_size_hex" "text_size_dec" \
    "baseline_text_sha256" "patched_text_sha256" "text_same" \
    "baseline_imports" "patched_imports" "baseline_strings" "patched_strings" \
    "symlink_signals_baseline" "symlink_signals_patched"
} > "$FULL_TSV"

# ---------------------------------------------------------------------------
# Process each Mach-O
# ---------------------------------------------------------------------------

total=0
changed_text=0
changed_whole=0
only_base=0
only_patch=0

while IFS=$'\t' read -r category rel; do
  [[ -n "$rel" ]] || continue
  total=$(( total + 1 ))

  if [[ "$category" == "unknown-root" ]]; then
    base_path="$BASE_ROOT/$rel"
    patch_path="$PATCH_ROOT/$rel"
  else
    base_path="$BASE_ROOT/$category/$rel"
    patch_path="$PATCH_ROOT/$category/$rel"
  fi

  base_present="no"
  patch_present="no"
  whole_same="-"
  [[ -f "$base_path" ]] && base_present="yes"
  [[ -f "$patch_path" ]] && patch_present="yes"

  if [[ "$base_present" == "yes" && "$patch_present" == "yes" ]]; then
    if cmp -s "$base_path" "$patch_path"; then
      whole_same="yes"
    else
      whole_same="no"
      changed_whole=$(( changed_whole + 1 ))
    fi
  fi

  [[ "$base_present" == "yes" && "$patch_present" == "no" ]] && only_base=$(( only_base + 1 ))
  [[ "$base_present" == "no" && "$patch_present" == "yes" ]] && only_patch=$(( only_patch + 1 ))

  arch=""
  if [[ "$base_present" == "yes" ]]; then
    arch="$(reverse_select_arch "$base_path")"
  elif [[ "$patch_present" == "yes" ]]; then
    arch="$(reverse_select_arch "$patch_path")"
  fi
  [[ -n "$arch" ]] || arch="-"

  text_offset="-"
  text_size_hex="-"
  text_size_dec="-"
  base_text_sha="-"
  patch_text_sha="-"
  text_same="-"
  base_imports="-"
  patch_imports="-"
  base_strings="-"
  patch_strings="-"
  base_syml="-"
  patch_syml="-"

  if [[ "$base_present" == "yes" && "$arch" != "-" ]]; then
    thin_base="$TMPDIR/base-$(printf '%s' "$rel" | tr '/ ' '__').thin"
    if get_thin_for_arch "$base_path" "$arch" "$thin_base"; then
      text_info="$(get_text_section "$thin_base")"
      if [[ -n "$text_info" ]]; then
        off="$(echo "$text_info" | awk '{print $1}')"
        sz="$(echo "$text_info" | awk '{print $2}')"
        text_offset="$off"
        text_size_hex="$sz"
        text_size_dec="$(reverse_hex_to_dec "$sz")"
        base_text_sha="$(hash_bytes "$thin_base" "$off" "$sz")"
        base_imports="$(count_imports "$thin_base")"
        base_strings="$(count_strings "$thin_base")"
        base_syml="$(symlink_signals "$thin_base")"
      fi
    fi
  fi

  if [[ "$patch_present" == "yes" && "$arch" != "-" ]]; then
    thin_patch="$TMPDIR/patch-$(printf '%s' "$rel" | tr '/ ' '__').thin"
    if get_thin_for_arch "$patch_path" "$arch" "$thin_patch"; then
      text_info="$(get_text_section "$thin_patch")"
      if [[ -n "$text_info" ]]; then
        off="$(echo "$text_info" | awk '{print $1}')"
        sz="$(echo "$text_info" | awk '{print $2}')"
        if [[ "$text_offset" == "-" ]]; then
          text_offset="$off"
          text_size_hex="$sz"
          text_size_dec="$(reverse_hex_to_dec "$sz")"
        fi
        patch_text_sha="$(hash_bytes "$thin_patch" "$off" "$sz")"
        patch_imports="$(count_imports "$thin_patch")"
        patch_strings="$(count_strings "$thin_patch")"
        patch_syml="$(symlink_signals "$thin_patch")"
      fi
    fi
  fi

  if [[ "$base_text_sha" != "-" && "$patch_text_sha" != "-" ]]; then
    if [[ "$base_text_sha" == "$patch_text_sha" ]]; then
      text_same="yes"
    else
      text_same="no"
      changed_text=$(( changed_text + 1 ))
    fi
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$rel" "$category" "$base_present" "$patch_present" "$whole_same" \
    "$arch" "$text_offset" "$text_size_hex" "$text_size_dec" \
    "$base_text_sha" "$patch_text_sha" "$text_same" \
    "$base_imports" "$patch_imports" "$base_strings" "$patch_strings" \
    "$base_syml" "$patch_syml" >> "$FULL_TSV"

done < "$ALL_MACHOS"

# ---------------------------------------------------------------------------
# Filtering
# ---------------------------------------------------------------------------

TSV="$OUT/matrix.tsv"
if [[ "$CHANGED_ONLY" -eq 0 && "$SIGNALS_ONLY" -eq 0 ]]; then
  cp "$FULL_TSV" "$TSV"
else
  {
    head -1 "$FULL_TSV"
    awk -F'\t' -v changed="$CHANGED_ONLY" -v signals="$SIGNALS_ONLY" \
      'NR>1 {
        pass=1
        if (changed==1) {
          if ($5 != "no" && $12 != "no" && $3=="yes" && $4=="yes") pass=0
        }
        if (signals==1) {
          if (($17+0)==0 && ($18+0)==0) pass=0
        }
        if (pass) print
      }' "$FULL_TSV"
  } > "$TSV"
fi

# ---------------------------------------------------------------------------
# JSONL conversion if requested
# ---------------------------------------------------------------------------

if [[ "$FORMAT" == "jsonl" ]]; then
  python3 -c '
import csv, json, sys
reader = csv.DictReader(sys.stdin, delimiter="\t")
for row in reader:
    # Coerce numeric fields
    for k in ["text_size_dec", "baseline_imports", "patched_imports",
              "baseline_strings", "patched_strings",
              "symlink_signals_baseline", "symlink_signals_patched"]:
        v = row.get(k, "-")
        if v != "-":
            try:
                row[k] = int(v)
            except ValueError:
                pass
    json.dump(row, sys.stdout)
    sys.stdout.write("\n")
' < "$TSV" > "$OUT/matrix.jsonl"
fi

# ---------------------------------------------------------------------------
# Markdown summary
# ---------------------------------------------------------------------------

SUMMARY="$OUT/summary.md"
{
  print -r -- "# Packet Text Matrix"
  print -r -- ""
  if [[ "$REGRESSION_TEST" -eq 1 ]]; then
    print -r -- "- mode: \`regression-test\`"
    print -r -- "- target: \`$REGRESSION_LABEL\`"
  else
    print -r -- "- baseline: \`$BASE_ROOT\`"
    print -r -- "- patched: \`$PATCH_ROOT\`"
  fi
  print -r -- "- generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  print -r -- "- format: \`$FORMAT\`"
  if [[ "$CHANGED_ONLY" -eq 1 || "$SIGNALS_ONLY" -eq 1 ]]; then
    print -r -- "- filters:"
    [[ "$CHANGED_ONLY" -eq 1 ]] && print -r -- "  - \`--changed-only\`"
    [[ "$SIGNALS_ONLY" -eq 1 ]] && print -r -- "  - \`--signals-only\`"
  fi
  print -r -- ""
  # Compute stats from the primary output TSV so filtered reports have consistent counts
  stat_line="$(awk -F'\t' 'NR>1 {
    total++
    if ($5=="no") cw++
    if ($12=="no") ct++
    if ($3=="no") ob++
    if ($4=="no") op++
  } END {
    printf "%d %d %d %d %d\n", total, cw+0, ct+0, ob+0, op+0
  }' "$TSV")"
  st_total="$(echo "$stat_line" | awk '{print $1}')"
  st_cw="$(echo "$stat_line" | awk '{print $2}')"
  st_ct="$(echo "$stat_line" | awk '{print $3}')"
  st_ob="$(echo "$stat_line" | awk '{print $4}')"
  st_op="$(echo "$stat_line" | awk '{print $5}')"

  print -r -- "## Statistics"
  print -r -- ""
  print -r -- "| metric | count |"
  print -r -- "| --- | --- |"
  print -r -- "| total Mach-O paths | $st_total |"
  print -r -- "| whole-file changed | $st_cw |"
  print -r -- "| __text changed | $st_ct |"
  print -r -- "| only in baseline | $st_ob |"
  print -r -- "| only in patched | $st_op |"
  print -r -- ""
  print -r -- "## Changed __text (rebase-aware)"
  print -r -- ""
  print -r -- "These binaries have different __TEXT,__text byte hashes after thinning to the same arch."
  print -r -- ""
  print -r -- "| rel_path | category | arch | text_size | baseline_imports | patched_imports | symlink_signals_baseline | symlink_signals_patched |"
  print -r -- "| --- | --- | --- | --- | --- | --- | --- | --- |"
  awk -F'\t' 'NR>1 && $12=="no" {
    printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $6, $8, $13, $14, $17, $18
  }' "$TSV"
  print -r -- ""
  print -r -- "## Unchanged __text but whole-file changed"
  print -r -- ""
  print -r -- "These binaries differ at the whole-file level (signature, rebase, metadata) but have identical __TEXT,__text code bytes."
  print -r -- ""
  print -r -- "| rel_path | category | arch | text_size |"
  print -r -- "| --- | --- | --- | --- |"
  awk -F'\t' 'NR>1 && $5=="no" && $12=="yes" {
    printf "| %s | %s | %s | %s |\n", $1, $2, $6, $8
  }' "$TSV"
  print -r -- ""
  print -r -- "## Only in one side"
  print -r -- ""
  awk -F'\t' 'NR>1 && ($3=="no" || $4=="no") {
    printf "- %s (category=%s baseline=%s patched=%s)\n", $1, $2, $3, $4
  }' "$TSV"
  print -r -- ""
  print -r -- "## Symlink-signal carriers"
  print -r -- ""
  awk -F'\t' 'NR>1 && ($17>0 || $18>0) {
    printf "- %s (category=%s baseline_signals=%s patched_signals=%s)\n", $1, $2, $17, $18
  }' "$TSV"
  print -r -- ""
  print -r -- "---"
  print -r -- ""
  print -r -- "Full TSV: \`full-matrix.tsv\`"
  print -r -- ""
  if [[ "$FORMAT" == "jsonl" ]]; then
    print -r -- "Primary output: \`matrix.jsonl\`"
  else
    print -r -- "Primary output: \`matrix.tsv\`"
  fi
} > "$SUMMARY"

# ---------------------------------------------------------------------------
# Regression test assertion
# ---------------------------------------------------------------------------

if [[ "$REGRESSION_TEST" -eq 1 ]]; then
  if [[ "$changed_text" -eq 0 && "$changed_whole" -eq 0 && "$only_base" -eq 0 && "$only_patch" -eq 0 ]]; then
    print -r -- "PASS: regression test on $REGRESSION_LABEL"
    print -r -- "$OUT"
    exit 0
  else
    print -r -- "FAIL: regression test on $REGRESSION_LABEL"
    print -r -- "  changed_text=$changed_text changed_whole=$changed_whole only_base=$only_base only_patch=$only_patch"
    print -r -- "$OUT"
    exit 1
  fi
fi

print -r -- "$OUT"
