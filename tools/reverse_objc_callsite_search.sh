#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common_reverse.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  reverse_objc_callsite_search.sh [-o outdir] [--max-slices n] <mach-o> <query>

Searches one Mach-O for an Objective-C selector, class name, method name, or C
symbol. It preserves raw search inputs, finds likely selector/import stubs and
branch callsites when possible, and emits focused callsite slices.
EOF
  exit 2
}

OUT=""
MAX_SLICES=12
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out)
      [[ $# -ge 2 ]] || usage
      OUT="$2"
      shift 2
      ;;
    --max-slices)
      [[ $# -ge 2 ]] || usage
      MAX_SLICES="$2"
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
QUERY="$2"
[[ -f "$BIN" ]] || reverse_die "Mach-O not found: $BIN"

[[ -n "$OUT" ]] || OUT="$(reverse_default_outdir objc-callsite-search "$BIN-$(reverse_safe_slug "$QUERY")")"
OUT="$(reverse_abs_path "$OUT")"
reverse_mkdirs "$OUT"

ARCH="$(reverse_select_arch "$BIN")"
[[ -n "$ARCH" ]] || reverse_die "Could not determine Mach-O arch for $BIN"

{
  print -r -- "input=$BIN"
  print -r -- "query=$QUERY"
  print -r -- "arch=$ARCH"
} > "$OUT/metadata/search-context.txt"

reverse_run_capture "$OUT/raw/strings-offsets.txt" strings -a -t x "$BIN"
reverse_run_capture "$OUT/raw/nm-all.txt" nm -arch "$ARCH" -m "$BIN"
reverse_run_capture "$OUT/raw/nm-undefined.txt" nm -arch "$ARCH" -m -u "$BIN"
reverse_run_capture "$OUT/raw/otool-Iv.txt" otool -arch "$ARCH" -Iv "$BIN"

if command -v dyld_info >/dev/null 2>&1; then
  reverse_run_capture "$OUT/raw/dyld_info-objc.txt" dyld_info -arch "$ARCH" -objc "$BIN"
  reverse_run_capture "$OUT/raw/dyld_info-imports.txt" dyld_info -arch "$ARCH" -imports "$BIN"
fi
if command -v objdump >/dev/null 2>&1; then
  reverse_run_capture "$OUT/raw/objdump-objc-meta-data.txt" objdump --macho --arch="$ARCH" --objc-meta-data "$BIN"
  reverse_run_capture "$OUT/raw/objdump-indirect-symbols.txt" objdump --macho --arch="$ARCH" --indirect-symbols "$BIN"
fi
if command -v ipsw >/dev/null 2>&1; then
  reverse_run_capture "$OUT/raw/ipsw-macho-objc-refs.txt" ipsw macho info --arch "$ARCH" --objc --objc-refs "$BIN"
fi

for f in strings-offsets nm-all nm-undefined otool-Iv dyld_info-objc dyld_info-imports objdump-objc-meta-data objdump-indirect-symbols ipsw-macho-objc-refs; do
  if [[ -f "$OUT/raw/$f.txt" ]]; then
    awk -v q="$QUERY" 'index(tolower($0),tolower(q))' "$OUT/raw/$f.txt" > "$OUT/normalized/matches-$f.txt" || true
  fi
done

: > "$OUT/normalized/callsites.tsv"
: > "$OUT/normalized/callsite-addresses.txt"
: > "$OUT/normalized/likely-symbol-addresses.txt"

awk -v q="$QUERY" '
  index(tolower($0),tolower(q)) {
    for (i=1;i<=NF;i++) {
      if ($i ~ /^0x[0-9a-fA-F]+$/) { print $i "\tobjc/meta\t" $0; next; }
      if (i == 1 && $i ~ /^[0-9a-fA-F]+$/) { print "0x"$i "\tsymbol\t" $0; next; }
    }
  }
' "$OUT/raw/nm-all.txt" "$OUT/raw/dyld_info-objc.txt" "$OUT/raw/objdump-objc-meta-data.txt" 2>/dev/null \
  | sort -u > "$OUT/normalized/likely-symbol-addresses.txt" || true

reverse_text_disassembly "$BIN" "$ARCH" "$OUT/raw/text.disass.txt"

if [[ "$QUERY" == *:* ]]; then
  reverse_selector_stubs "$BIN" "$ARCH" "$QUERY" "$OUT/raw/selector-search"
  cp "$OUT/raw/selector-search/selector-refs.txt" "$OUT/normalized/selector-refs.txt" 2>/dev/null || true
  cp "$OUT/raw/selector-search/selector-stubs.tsv" "$OUT/normalized/selector-stubs.tsv" 2>/dev/null || true

  while IFS=$'\t' read -r stub selref desc; do
    [[ "$stub" == 0x* ]] || continue
    reverse_branch_callsites_for_target "$OUT/raw/text.disass.txt" "$stub" \
      | awk -F'\t' -v stub="$stub" -v selref="$selref" -v query="$QUERY" '{print "selector\t" query "\t" stub "\t" selref "\t" $1 "\t" $2}' \
      >> "$OUT/normalized/callsites.tsv"
  done < "$OUT/normalized/selector-stubs.tsv"
fi

reverse_import_stubs "$BIN" "$ARCH" "$QUERY" "$OUT/normalized/import-stubs.txt"
while IFS= read -r line; do
  stub="$(print -r -- "$line" | awk '$1 ~ /^0x[0-9a-fA-F]+$/ {print $1; exit}')"
  [[ "$stub" == 0x* ]] || continue
  reverse_branch_callsites_for_target "$OUT/raw/text.disass.txt" "$stub" \
    | awk -F'\t' -v stub="$stub" -v query="$QUERY" '{print "import\t" query "\t" stub "\t-\t" $1 "\t" $2}' \
    >> "$OUT/normalized/callsites.tsv"
done < "$OUT/normalized/import-stubs.txt"

{
  awk -v q="$QUERY" 'index(tolower($0),tolower(q)) && $1 ~ /^0x[0-9a-fA-F]+$/ {print $1 "\t" $0}' "$OUT/raw/objdump-indirect-symbols.txt" 2>/dev/null || true
  awk -v q="$QUERY" 'index(tolower($0),tolower(q)) && $1 ~ /^[0-9a-fA-F]+$/ {print "0x"$1 "\t" $0}' "$OUT/raw/nm-all.txt" 2>/dev/null || true
} | sort -u > "$OUT/normalized/class-or-symbol-refs.tsv"

: > "$OUT/normalized/classref-contexts.txt"
while IFS=$'\t' read -r ref rest; do
  [[ "$ref" == 0x* ]] || continue
  page="$(reverse_addr_page "$ref")"
  off="$(reverse_addr_page_off "$ref")"
  awk -v page="$page" -v off="#${off}" -v ref="$ref" -v query="$QUERY" '
    /^0x[0-9a-fA-F]+:/ {
      addr=$1; sub(/:$/, "", addr);
      ring[NR % 10]=$0;
    }
    index($0,page) { candidate=addr; next; }
    candidate != "" && index($0,off) {
      print "---- class/symbol ref " ref " query " query " near " candidate " ----";
      for (i=9; i>=1; i--) {
        n=NR-i; k=n%10;
        if (ring[k] != "") print ring[k];
      }
      print $0;
      tail=14;
      candidate="";
      next;
    }
    tail > 0 { print; tail--; }
  ' "$OUT/raw/text.disass.txt" >> "$OUT/normalized/classref-contexts.txt"
done < "$OUT/normalized/class-or-symbol-refs.tsv"

awk -F'\t' '$5 ~ /^0x[0-9a-fA-F]+$/ {print $5}' "$OUT/normalized/callsites.tsv" | sort -u > "$OUT/normalized/callsite-addresses.txt" || true

slice_count=0
while IFS= read -r addr; do
  [[ "$addr" == 0x* ]] || continue
  slice_count=$(( slice_count + 1 ))
  [[ "$slice_count" -le "$MAX_SLICES" ]] || break
  safe="${addr#0x}"
  start="$(reverse_hex_add_dec "$addr" -64)"
  reverse_disassemble_slice "$BIN" "$ARCH" "$start" 64 "$OUT/slices/callsite-$safe.disass.txt"
  reverse_normalize_disassembly "$OUT/slices/callsite-$safe.disass.txt" "$OUT/slices/callsite-$safe.normalized.txt"
done < "$OUT/normalized/callsite-addresses.txt"

sym_slice_count=0
while IFS=$'\t' read -r addr source line; do
  [[ "$addr" == 0x* ]] || continue
  sym_slice_count=$(( sym_slice_count + 1 ))
  [[ "$sym_slice_count" -le "$MAX_SLICES" ]] || break
  safe="${addr#0x}"
  start="$(reverse_hex_add_dec "$addr" -64)"
  reverse_disassemble_slice "$BIN" "$ARCH" "$start" 96 "$OUT/slices/symbol-$safe.disass.txt"
  reverse_normalize_disassembly "$OUT/slices/symbol-$safe.disass.txt" "$OUT/slices/symbol-$safe.normalized.txt"
done < "$OUT/normalized/likely-symbol-addresses.txt"

{
  print -r -- "# Objective-C Callsite Search"
  print -r -- ""
  print -r -- "- input: \`$BIN\`"
  print -r -- "- query: \`$QUERY\`"
  print -r -- "- arch used: \`$ARCH\`"
  print -r -- "- output: \`$OUT\`"
  print -r -- ""
  print -r -- "## Matches"
  print -r -- ""
  for f in "$OUT"/normalized/matches-*.txt; do
    [[ -f "$f" ]] || continue
    count="$(wc -l < "$f" | tr -d ' ')"
    print -r -- "- \`${f:t}\`: $count"
  done
  print -r -- ""
  print -r -- "## Selector Stubs"
  print -r -- ""
  if [[ -s "$OUT/normalized/selector-stubs.tsv" ]]; then
    awk -F'\t' '{print "- stub `" $1 "` selector-ref `" $2 "`"}' "$OUT/normalized/selector-stubs.tsv"
  else
    print -r -- "- none found"
  fi
  print -r -- ""
  print -r -- "## Callsites"
  print -r -- ""
  if [[ -s "$OUT/normalized/callsites.tsv" ]]; then
    print -r -- "| kind | query | stub | ref | callsite | note |"
    print -r -- "|---|---|---|---|---|---|"
    awk -F'\t' '{gsub(/\|/,"\\\\|",$6); print "| " $1 " | `" $2 "` | `" $3 "` | `" $4 "` | `" $5 "` | " $6 " |"}' "$OUT/normalized/callsites.tsv"
  else
    print -r -- "No branch callsites found from selector/import stubs. Check classref contexts and symbol slices."
  fi
  print -r -- ""
  print -r -- "## Files"
  print -r -- ""
  print -r -- "- callsite table: \`normalized/callsites.tsv\`"
  print -r -- "- likely symbol addresses: \`normalized/likely-symbol-addresses.txt\`"
  print -r -- "- class/symbol ref contexts: \`normalized/classref-contexts.txt\`"
  print -r -- "- focused slices: \`slices/\`"
} > "$OUT/summary.md"

print -r -- "$OUT"
