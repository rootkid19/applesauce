#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common_reverse.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  reverse_function_slice.sh [-o outdir] [-c instruction-count] [-p pre-bytes] <mach-o> <address-or-symbol-hint>

Builds a focused static slice around a Mach-O address, symbol, Objective-C
method, or selector hint. The slice records raw disassembly, nearby labels,
matching selector refs/stubs, relevant strings, and normalized disassembly for
cross-build comparison.
EOF
  exit 2
}

OUT=""
COUNT=180
PRE_BYTES=128

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
    -p|--pre-bytes)
      [[ $# -ge 2 ]] || usage
      PRE_BYTES="$2"
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

[[ $# -eq 2 ]] || usage
BIN="$(reverse_abs_path "$1")"
HINT="$2"
[[ -f "$BIN" ]] || reverse_die "Mach-O not found: $BIN"

[[ -n "$OUT" ]] || OUT="$(reverse_default_outdir function-slice "$BIN-$(reverse_safe_slug "$HINT")")"
OUT="$(reverse_abs_path "$OUT")"
reverse_mkdirs "$OUT"

ARCH="$(reverse_select_arch "$BIN")"
[[ -n "$ARCH" ]] || reverse_die "Could not determine Mach-O arch for $BIN"

ADDR="$(reverse_resolve_hint "$BIN" "$ARCH" "$HINT")"
[[ -n "$ADDR" ]] || reverse_die "Could not resolve hint in $BIN: $HINT"
START_ADDR="$(reverse_hex_add_dec "$ADDR" "-$PRE_BYTES")"
STOP_ADDR="$(reverse_hex_add_dec "$START_ADDR" $(( COUNT * 4 )))"
FILE_OFF="$(reverse_addr_to_offset "$BIN" "$ARCH" "$ADDR")"
START_OFF="$(reverse_addr_to_offset "$BIN" "$ARCH" "$START_ADDR")"
STOP_OFF="$(reverse_addr_to_offset "$BIN" "$ARCH" "$STOP_ADDR")"

{
  print -r -- "input=$BIN"
  print -r -- "hint=$HINT"
  print -r -- "arch=$ARCH"
  print -r -- "resolved_address=$ADDR"
  print -r -- "slice_start=$START_ADDR"
  print -r -- "slice_stop=$STOP_ADDR"
  print -r -- "file_offset=${FILE_OFF:-unknown}"
  print -r -- "instruction_count=$COUNT"
  print -r -- "pre_bytes=$PRE_BYTES"
} > "$OUT/metadata/slice-context.txt"

reverse_neighbor_labels "$BIN" "$ARCH" "$ADDR" "$OUT/normalized/nearby-function-labels.txt"
reverse_disassemble_slice "$BIN" "$ARCH" "$START_ADDR" "$COUNT" "$OUT/raw/disassembly.txt"
reverse_normalize_disassembly "$OUT/raw/disassembly.txt" "$OUT/normalized/disassembly.normalized.txt"

reverse_run_capture "$OUT/raw/nm-hint-matches.txt" nm -arch "$ARCH" -m "$BIN"
awk -v q="$HINT" 'index($0,q)' "$OUT/raw/nm-hint-matches.txt" > "$OUT/normalized/symbol-matches.txt" || true

if command -v dyld_info >/dev/null 2>&1; then
  reverse_run_capture "$OUT/raw/dyld_info-objc.txt" dyld_info -arch "$ARCH" -objc "$BIN"
  awk -v q="$HINT" 'index($0,q)' "$OUT/raw/dyld_info-objc.txt" > "$OUT/normalized/objc-hint-matches.txt" || true
fi

if [[ "$HINT" == *:* ]]; then
  reverse_selector_stubs "$BIN" "$ARCH" "$HINT" "$OUT/raw/selector-search"
  cp "$OUT/raw/selector-search/selector-refs.txt" "$OUT/normalized/selector-refs.txt" 2>/dev/null || true
  cp "$OUT/raw/selector-search/selector-stubs.tsv" "$OUT/normalized/selector-stubs.tsv" 2>/dev/null || true
else
  : > "$OUT/normalized/selector-refs.txt"
  : > "$OUT/normalized/selector-stubs.tsv"
fi

reverse_run_capture "$OUT/raw/strings-offsets.txt" strings -a -t x "$BIN"
if [[ -n "$START_OFF" && -n "$STOP_OFF" ]]; then
  START_OFF_DEC="$(reverse_hex_to_dec "$START_OFF")"
  STOP_OFF_DEC="$(reverse_hex_to_dec "$STOP_OFF")"
  awk -v s="$START_OFF_DEC" -v e="$STOP_OFF_DEC" '
    function h2d(h, i,c,v,d) {
      d=0;
      for (i=1; i<=length(h); i++) {
        c=substr(h,i,1);
        v=index("0123456789abcdef", tolower(c))-1;
        d=d*16+v;
      }
      return d;
    }
    $1 ~ /^[0-9a-fA-F]+$/ {
      d=h2d($1);
      if (d >= s-4096 && d <= e+4096) print;
    }
  ' "$OUT/raw/strings-offsets.txt" > "$OUT/normalized/nearby-strings.txt" || true
else
  : > "$OUT/normalized/nearby-strings.txt"
fi
awk -v q="$HINT" 'index($0,q)' "$OUT/raw/strings-offsets.txt" > "$OUT/normalized/hint-string-matches.txt" || true

{
  print -r -- "# Function Slice"
  print -r -- ""
  print -r -- "- input: \`$BIN\`"
  print -r -- "- hint: \`$HINT\`"
  print -r -- "- arch used: \`$ARCH\`"
  print -r -- "- resolved address: \`$ADDR\`"
  print -r -- "- file offset: \`${FILE_OFF:-unknown}\`"
  print -r -- "- slice range: \`$START_ADDR..$STOP_ADDR\`"
  print -r -- "- output: \`$OUT\`"
  print -r -- ""
  print -r -- "## Nearby Labels"
  print -r -- ""
  sed 's/^/- /' "$OUT/normalized/nearby-function-labels.txt" 2>/dev/null || true
  print -r -- ""
  print -r -- "## Selector Stubs"
  print -r -- ""
  if [[ -s "$OUT/normalized/selector-stubs.tsv" ]]; then
    awk -F'\t' '{print "- `" $1 "` selector-ref `" $2 "` " $3}' "$OUT/normalized/selector-stubs.tsv"
  else
    print -r -- "- none found for this hint"
  fi
  print -r -- ""
  print -r -- "## Files"
  print -r -- ""
  print -r -- "- raw disassembly: \`raw/disassembly.txt\`"
  print -r -- "- normalized disassembly: \`normalized/disassembly.normalized.txt\`"
  print -r -- "- nearby strings: \`normalized/nearby-strings.txt\`"
} > "$OUT/summary.md"

print -r -- "$OUT"
