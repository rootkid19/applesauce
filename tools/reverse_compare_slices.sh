#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common_reverse.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  reverse_compare_slices.sh [-o outdir] [-c instruction-count] <26.4-mach-o> <26.5-mach-o> <26.4-address-or-hint> <26.5-address-or-hint>

Runs reverse_function_slice.sh for both inputs, keeps raw slice directories, and
writes a compact normalized Markdown diff.
EOF
  exit 2
}

OUT=""
COUNT=220
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out)
      [[ $# -ge 2 ]] || usage
      OUT="$2"
      shift 2
      ;;
    -c|--count)
      [[ $# -ge 2 ]] || usage
      COUNT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -eq 4 ]] || usage
BIN_A="$(reverse_abs_path "$1")"
BIN_B="$(reverse_abs_path "$2")"
HINT_A="$3"
HINT_B="$4"
[[ -f "$BIN_A" ]] || reverse_die "26.4 Mach-O not found: $BIN_A"
[[ -f "$BIN_B" ]] || reverse_die "26.5 Mach-O not found: $BIN_B"

[[ -n "$OUT" ]] || OUT="$(reverse_default_outdir compare-slices "$(basename "$BIN_A")-$(reverse_safe_slug "$HINT_A")")"
OUT="$(reverse_abs_path "$OUT")"
reverse_mkdirs "$OUT"

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
SLICE_A="$OUT/raw/26.4-slice"
SLICE_B="$OUT/raw/26.5-slice"

{
  print -r -- "26.4 binary=$BIN_A"
  print -r -- "26.5 binary=$BIN_B"
  print -r -- "26.4 hint=$HINT_A"
  print -r -- "26.5 hint=$HINT_B"
  print -r -- "instruction_count=$COUNT"
} > "$OUT/metadata/compare-context.txt"

{
  print -r -- "command: $TOOLS_DIR/reverse_function_slice.sh -o $SLICE_A -c $COUNT $BIN_A $HINT_A"
  "$TOOLS_DIR/reverse_function_slice.sh" -o "$SLICE_A" -c "$COUNT" "$BIN_A" "$HINT_A"
} > "$OUT/raw/run-26.4-slice.stdout.txt" 2> "$OUT/raw/run-26.4-slice.stderr.txt" || {
  cat "$OUT/raw/run-26.4-slice.stderr.txt" >&2
  exit 2
}

{
  print -r -- "command: $TOOLS_DIR/reverse_function_slice.sh -o $SLICE_B -c $COUNT $BIN_B $HINT_B"
  "$TOOLS_DIR/reverse_function_slice.sh" -o "$SLICE_B" -c "$COUNT" "$BIN_B" "$HINT_B"
} > "$OUT/raw/run-26.5-slice.stdout.txt" 2> "$OUT/raw/run-26.5-slice.stderr.txt" || {
  cat "$OUT/raw/run-26.5-slice.stderr.txt" >&2
  exit 2
}

diff -u "$SLICE_A/normalized/disassembly.normalized.txt" "$SLICE_B/normalized/disassembly.normalized.txt" > "$OUT/normalized/disassembly.diff" 2>&1 || true
paste "$SLICE_A/normalized/disassembly.normalized.txt" "$SLICE_B/normalized/disassembly.normalized.txt" > "$OUT/normalized/disassembly.side-by-side.txt" 2>/dev/null || true

{
  print -r -- "# Normalized Slice Diff"
  print -r -- ""
  print -r -- "- 26.4 binary: \`$BIN_A\`"
  print -r -- "- 26.5 binary: \`$BIN_B\`"
  print -r -- "- 26.4 hint: \`$HINT_A\`"
  print -r -- "- 26.5 hint: \`$HINT_B\`"
  print -r -- "- output: \`$OUT\`"
  print -r -- ""
  print -r -- "## Resolved Context"
  print -r -- ""
  print -r -- "### 26.4"
  sed 's/^/- /' "$SLICE_A/metadata/slice-context.txt" 2>/dev/null || true
  print -r -- ""
  print -r -- "### 26.5"
  sed 's/^/- /' "$SLICE_B/metadata/slice-context.txt" 2>/dev/null || true
  print -r -- ""
  print -r -- "## Diff Preview"
  print -r -- ""
  print -r -- '```diff'
  sed -n '1,220p' "$OUT/normalized/disassembly.diff"
  print -r -- '```'
  print -r -- ""
  print -r -- "Raw slice outputs are under \`raw/26.4-slice/\` and \`raw/26.5-slice/\`."
} > "$OUT/summary.md"

print -r -- "$OUT"
