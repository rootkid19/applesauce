#!/bin/zsh
set -euo pipefail
unsetopt verbose xtrace

# reverse_packet_text_matrix.sh
#
# Given two collected artifact roots, emit a deterministic TSV/Markdown matrix
# of executable Mach-O files with:
#   - whole-file SHA-256 comparison
#   - best-arch selection (arm64e > arm64 > first available)
#   - __TEXT,__text offset, size, and SHA-256 of exact text bytes
#   - import count, string count
#   - symlink/path-hardening signal counts (strings + imports)
#
# This is designed for Apple patch-diff research: it separates rebase/signature
# drift from actual __text changes by hashing the exact code-section bytes.
#
# usage:
#   reverse_packet_text_matrix.sh <baseline-root> <patched-root> [outdir]
#
# example:
#   reverse_packet_text_matrix.sh \
#     artifacts/packet007-syncservices-contacts/26.4 \
#     artifacts/packet007-syncservices-contacts/26.5
#
# Output:
#   matrix.tsv       - machine-readable tab-separated values
#   summary.md       - human-readable Markdown summary with change statistics
#
# Deterministic requirements:
#   - lipo, otool, file, strings, cmp, shasum, python3, awk

source "$(cd "$(dirname "${(%):-%x}")" && pwd)/common.sh"
source "$(cd "$(dirname "${(%):-%x}")" && pwd)/common_reverse.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  reverse_packet_text_matrix.sh <baseline-root> <patched-root> [outdir]

examples:
  reverse_packet_text_matrix.sh artifacts/packet007-syncservices-contacts/26.4 \
                                 artifacts/packet007-syncservices-contacts/26.5

  reverse_packet_text_matrix.sh artifacts/packet007-syncservices-contacts/26.4-expanded \
                                 artifacts/packet007-syncservices-contacts/26.5-expanded \
                                 artifacts/packet007-syncservices-contacts/text-matrix-expanded
EOF
  exit 2
}

[[ $# -ge 2 && $# -le 3 ]] || usage

BASE_ROOT="${1:A}"
PATCH_ROOT="${2:A}"

if [[ $# -eq 3 ]]; then
  OUT="${3:A}"
else
  OUT="$(artifact_root)/packet007-syncservices-contacts/text-matrix-$(basename "$BASE_ROOT")-vs-$(basename "$PATCH_ROOT")"
fi

[[ -d "$BASE_ROOT" ]] || reverse_die "baseline root not found: $BASE_ROOT"
[[ -d "$PATCH_ROOT" ]] || reverse_die "patched root not found: $PATCH_ROOT"

mkdir -p "$OUT"

TMPDIR="$(mktemp -d)"
trap "rm -rf '$TMPDIR'" EXIT

# Symlink/path hardening vocabulary (case-insensitive grep)
SYMLINK_PATTERN='symlink|readlink|realpath|lstat|fstatat|openat|getattrlist|faccessat|O_NOFOLLOW|URLByResolvingSymlinksInPath|standardizedURL|destinationOfSymbolicLink|isSymbolicLink|ResolvingSymlinksInPath'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_macho() {
  file "$1" 2>/dev/null | grep -q "Mach-O"
}

# Return a thin copy of the binary using the best available arch.
# If already thin and matches desired, copy directly.
# If universal, lipo -thin to temp.
# Fallback to first available arch.
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

  # Fallback: first available arch
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

# Extract __TEXT,__text offset and size from otool -l output.
# Prints: "<offset> <size_hex>"
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

# Hash exactly `count` bytes starting at `offset` in `bin` using python3.
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

# Count imports from otool -Iv (exclude header lines)
count_imports() {
  local thin="$1"
  otool -Iv "$thin" 2>/dev/null | awk 'NR>3 && $1 ~ /^0x[0-9a-fA-F]+$/ {c++} END {print c+0}'
}

# Count strings
count_strings() {
  local thin="$1"
  strings "$thin" 2>/dev/null | wc -l | tr -d ' '
}

# Count symlink signals in strings + imports
symlink_signals() {
  local thin="$1"
  local str_count import_count
  str_count="$(strings "$thin" 2>/dev/null | grep -ciE "$SYMLINK_PATTERN" || true)"
  import_count="$(otool -Iv "$thin" 2>/dev/null | grep -ciE "$SYMLINK_PATTERN" || true)"
  echo "$(( str_count + import_count ))"
}

# ---------------------------------------------------------------------------
# Discovery: find all Mach-O files under standalone/ in both roots
# ---------------------------------------------------------------------------

BASE_MACHOS="$TMPDIR/base.machos.txt"
PATCH_MACHOS="$TMPDIR/patch.machos.txt"
ALL_MACHOS="$TMPDIR/all.machos.txt"

: > "$BASE_MACHOS"
: > "$PATCH_MACHOS"

find_machos() {
  local root="$1"
  local out="$2"
  if [[ -d "$root/standalone" ]]; then
    (cd "$root/standalone" && find . -type f -print) | while read -r rel; do
      rel="${rel#./}"
      [[ -n "$rel" ]] || continue
      if is_macho "$root/standalone/$rel"; then
        print -r -- "$rel"
      fi
    done > "$out"
  else
    # If no standalone/ subdir, search from root directly
    (cd "$root" && find . -type f -print) | while read -r rel; do
      rel="${rel#./}"
      [[ -n "$rel" ]] || continue
      if is_macho "$root/$rel"; then
        print -r -- "$rel"
      fi
    done > "$out"
  fi
}

find_machos "$BASE_ROOT" "$BASE_MACHOS"
find_machos "$PATCH_ROOT" "$PATCH_MACHOS"

sort -u "$BASE_MACHOS" "$PATCH_MACHOS" > "$ALL_MACHOS"

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

TSV="$OUT/matrix.tsv"
{
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "rel_path" "category" "baseline_present" "patched_present" "whole_file_same" \
    "arch" "text_offset" "text_size_hex" "text_size_dec" \
    "baseline_text_sha256" "patched_text_sha256" "text_same" \
    "baseline_imports" "patched_imports" "baseline_strings" "patched_strings" \
    "symlink_signals_baseline" "symlink_signals_patched"
} > "$TSV"

# ---------------------------------------------------------------------------
# Process each Mach-O
# ---------------------------------------------------------------------------

total=0
changed_text=0
changed_whole=0
only_base=0
only_patch=0

while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  total=$(( total + 1 ))

  base_path="$BASE_ROOT/standalone/$rel"
  patch_path="$PATCH_ROOT/standalone/$rel"
  [[ -f "$base_path" ]] || base_path="$BASE_ROOT/$rel"
  [[ -f "$patch_path" ]] || patch_path="$PATCH_ROOT/$rel"

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

  # Determine best arch: prefer arm64e, then arm64, then first available.
  arch=""
  if [[ "$base_present" == "yes" ]]; then
    arch="$(reverse_select_arch "$base_path")"
  elif [[ "$patch_present" == "yes" ]]; then
    arch="$(reverse_select_arch "$patch_path")"
  fi
  [[ -n "$arch" ]] || arch="-"

  # Thin copies
  thin_base=""
  thin_patch=""
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
    thin_base="$TMPDIR/base-$(print -r -- "$rel" | tr '/ ' '__').thin"
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
    thin_patch="$TMPDIR/patch-$(print -r -- "$rel" | tr '/ ' '__').thin"
    if get_thin_for_arch "$patch_path" "$arch" "$thin_patch"; then
      text_info="$(get_text_section "$thin_patch")"
      if [[ -n "$text_info" ]]; then
        off="$(echo "$text_info" | awk '{print $1}')"
        sz="$(echo "$text_info" | awk '{print $2}')"
        # Only set if not already set from baseline (they should match)
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
    "$rel" "standalone" "$base_present" "$patch_present" "$whole_same" \
    "$arch" "$text_offset" "$text_size_hex" "$text_size_dec" \
    "$base_text_sha" "$patch_text_sha" "$text_same" \
    "$base_imports" "$patch_imports" "$base_strings" "$patch_strings" \
    "$base_syml" "$patch_syml" >> "$TSV"

done < "$ALL_MACHOS"

# ---------------------------------------------------------------------------
# Markdown summary
# ---------------------------------------------------------------------------

SUMMARY="$OUT/summary.md"
{
  print -r -- "# Packet Text Matrix"
  print -r -- ""
  print -r -- "- baseline: \`$BASE_ROOT\`"
  print -r -- "- patched: \`$PATCH_ROOT\`"
  print -r -- "- generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  print -r -- ""
  print -r -- "## Statistics"
  print -r -- ""
  print -r -- "| metric | count |"
  print -r -- "| --- | --- |"
  print -r -- "| total Mach-O paths | $total |"
  print -r -- "| whole-file changed | $changed_whole |"
  print -r -- "| __text changed | $changed_text |"
  print -r -- "| only in baseline | $only_base |"
  print -r -- "| only in patched | $only_patch |"
  print -r -- ""
  print -r -- "## Changed __text (rebase-aware)"
  print -r -- ""
  print -r -- "These binaries have different __TEXT,__text byte hashes after thinning to the same arch."
  print -r -- ""
  print -r -- "| rel_path | arch | text_size | baseline_imports | patched_imports | symlink_signals_baseline | symlink_signals_patched |"
  print -r -- "| --- | --- | --- | --- | --- | --- | --- |"
  awk -F'\t' 'NR>1 && $12=="no" {
    printf "| %s | %s | %s | %s | %s | %s | %s |\n", $1, $6, $8, $13, $14, $17, $18
  }' "$TSV"
  print -r -- ""
  print -r -- "## Unchanged __text but whole-file changed"
  print -r -- ""
  print -r -- "These binaries differ at the whole-file level (signature, rebase, metadata) but have identical __TEXT,__text code bytes."
  print -r -- ""
  print -r -- "| rel_path | arch | text_size |"
  print -r -- "| --- | --- | --- |"
  awk -F'\t' 'NR>1 && $5=="no" && $12=="yes" {
    printf "| %s | %s | %s |\n", $1, $6, $8
  }' "$TSV"
  print -r -- ""
  print -r -- "## Only in one side"
  print -r -- ""
  awk -F'\t' 'NR>1 && ($3=="no" || $4=="no") {
    printf "- %s (baseline=%s patched=%s)\n", $1, $3, $4
  }' "$TSV"
  print -r -- ""
  print -r -- "---"
  print -r -- ""
  print -r -- "Full TSV: \`matrix.tsv\`"
} > "$SUMMARY"

print -r -- "$OUT"
