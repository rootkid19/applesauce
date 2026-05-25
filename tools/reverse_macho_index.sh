#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common_reverse.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  reverse_macho_index.sh [-o outdir] <mach-o>

Builds a normalized static index for one Mach-O. Raw command output is preserved
under raw/, normalized triage files under normalized/, and summary.md records
arch/tool provenance.
EOF
  exit 2
}

OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out)
      [[ $# -ge 2 ]] || usage
      OUT="$2"
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

[[ $# -eq 1 ]] || usage
BIN="$(reverse_abs_path "$1")"
[[ -f "$BIN" ]] || reverse_die "Mach-O not found: $BIN"

[[ -n "$OUT" ]] || OUT="$(reverse_default_outdir macho-index "$BIN")"
OUT="$(reverse_abs_path "$OUT")"
reverse_mkdirs "$OUT"

ARCH="$(reverse_select_arch "$BIN")"
[[ -n "$ARCH" ]] || reverse_die "Could not determine Mach-O arch for $BIN"

print -r -- "$BIN" > "$OUT/metadata/input.txt"
print -r -- "$ARCH" > "$OUT/metadata/arch-used.txt"
reverse_tool_inventory "$OUT"

reverse_run_capture "$OUT/raw/file.txt" file "$BIN"
reverse_run_capture "$OUT/raw/ls.txt" ls -laeO@ "$BIN"
reverse_run_capture "$OUT/raw/sha256.txt" shasum -a 256 "$BIN"
reverse_run_capture "$OUT/raw/lipo-archs.txt" lipo -archs "$BIN"
reverse_run_capture "$OUT/raw/dwarfdump-uuid.txt" dwarfdump --uuid "$BIN"
reverse_run_capture "$OUT/raw/vtool-show.txt" vtool -show "$BIN"
reverse_run_capture "$OUT/raw/otool-hv.txt" otool -arch "$ARCH" -hv "$BIN"
reverse_run_capture "$OUT/raw/otool-l.txt" otool -arch "$ARCH" -l "$BIN"
reverse_run_capture "$OUT/raw/otool-L.txt" otool -arch "$ARCH" -L "$BIN"
reverse_run_capture "$OUT/raw/otool-D.txt" otool -arch "$ARCH" -D "$BIN"
reverse_run_capture "$OUT/raw/otool-Iv.txt" otool -arch "$ARCH" -Iv "$BIN"
reverse_run_capture "$OUT/raw/nm-all.txt" nm -arch "$ARCH" -m "$BIN"
reverse_run_capture "$OUT/raw/nm-undefined.txt" nm -arch "$ARCH" -m -u "$BIN"
reverse_run_capture "$OUT/raw/strings-offsets.txt" strings -a -t x "$BIN"
reverse_run_capture "$OUT/raw/codesign-entitlements.txt" codesign -d --entitlements - "$BIN"

if command -v dyld_info >/dev/null 2>&1; then
  for opt in uuid platform segments linked_dylibs imports exports objc function_starts load_commands fixups fixup_chains; do
    reverse_run_capture "$OUT/raw/dyld_info-$opt.txt" dyld_info -arch "$ARCH" "-$opt" "$BIN"
  done
fi

if command -v objdump >/dev/null 2>&1; then
  reverse_run_capture "$OUT/raw/objdump-objc-meta-data.txt" objdump --macho --arch="$ARCH" --objc-meta-data "$BIN"
  reverse_run_capture "$OUT/raw/objdump-indirect-symbols.txt" objdump --macho --arch="$ARCH" --indirect-symbols "$BIN"
  reverse_run_capture "$OUT/raw/objdump-function-starts.txt" objdump --macho --arch="$ARCH" --function-starts=both "$BIN"
  reverse_run_capture "$OUT/raw/objdump-dylibs-used.txt" objdump --macho --arch="$ARCH" --dylibs-used "$BIN"
  reverse_run_capture "$OUT/raw/objdump-exports-trie.txt" objdump --macho --arch="$ARCH" --exports-trie "$BIN"
fi

if command -v ipsw >/dev/null 2>&1; then
  reverse_run_capture "$OUT/raw/ipsw-macho-loads.txt" ipsw macho info --arch "$ARCH" --loads "$BIN"
  reverse_run_capture "$OUT/raw/ipsw-macho-symbols.txt" ipsw macho info --arch "$ARCH" --symbols "$BIN"
  reverse_run_capture "$OUT/raw/ipsw-macho-strings.txt" ipsw macho info --arch "$ARCH" --strings "$BIN"
  reverse_run_capture "$OUT/raw/ipsw-macho-objc-refs.txt" ipsw macho info --arch "$ARCH" --objc --objc-refs "$BIN"
  reverse_run_capture "$OUT/raw/ipsw-macho-starts.txt" ipsw macho info --arch "$ARCH" --starts "$BIN"
  reverse_run_capture "$OUT/raw/ipsw-macho-signature.txt" ipsw macho info --arch "$ARCH" --sig "$BIN"
  reverse_run_capture "$OUT/raw/ipsw-macho-entitlements.txt" ipsw macho info --arch "$ARCH" --ent "$BIN"
fi

if command -v jtool2 >/dev/null 2>&1; then
  reverse_probe_capture "$OUT/raw/jtool2-version" 4 jtool2 --version
  if [[ "$(cat "$OUT/raw/jtool2-version.status.txt" 2>/dev/null || true)" == "0" ]]; then
    reverse_probe_capture "$OUT/raw/jtool2-load-commands" 8 jtool2 -l "$BIN"
    reverse_probe_capture "$OUT/raw/jtool2-symbols" 8 jtool2 -S "$BIN"
  fi
fi

cp "$OUT/raw/file.txt" "$OUT/normalized/file-info.txt" 2>/dev/null || true
cp "$OUT/raw/dwarfdump-uuid.txt" "$OUT/normalized/uuids.txt" 2>/dev/null || true
awk 'NR > 1 && NF {print}' "$OUT/raw/otool-D.txt" > "$OUT/normalized/install-name.txt" 2>/dev/null || true
awk 'NR > 1 && NF {print}' "$OUT/raw/otool-L.txt" > "$OUT/normalized/linked-dylibs.txt" 2>/dev/null || true

awk 'index($0,"(undefined)") {print}' "$OUT/raw/nm-undefined.txt" | sort -u > "$OUT/normalized/imports-undefined-symbols.txt" || true
awk '$1 ~ /^[0-9a-fA-F]+$/ && index($0,"(__TEXT") {print}' "$OUT/raw/nm-all.txt" | sort -u > "$OUT/normalized/defined-text-symbols.txt" || true
awk '$1 ~ /^[0-9a-fA-F]+$/ && !index($0,"(undefined)") {print}' "$OUT/raw/nm-all.txt" | sort -u > "$OUT/normalized/defined-symbols.txt" || true
awk 'index($0," external ") && !index($0,"(undefined)") {print}' "$OUT/raw/nm-all.txt" | sort -u > "$OUT/normalized/exports-defined-symbols.txt" || true

{
  awk 'index($0,"_OBJC_CLASS_$_") {print}' "$OUT/raw/nm-all.txt" 2>/dev/null || true
  awk 'index($0,"_OBJC_CLASS_$_") {print}' "$OUT/raw/objdump-indirect-symbols.txt" 2>/dev/null || true
} | sort -u > "$OUT/normalized/objc-classrefs.txt"

{
  awk '/@interface / {print $2}' "$OUT/raw/dyld_info-objc.txt" 2>/dev/null || true
  awk '/@interface / {print $2}' "$OUT/raw/objdump-objc-meta-data.txt" 2>/dev/null || true
  awk 'index($0,"_OBJC_CLASS_$_") {sub(/^.*_OBJC_CLASS_\$_/,""); sub(/[[:space:]].*$/,""); print}' "$OUT/raw/nm-all.txt" 2>/dev/null || true
} | sed 's/[,:].*$//' | sort -u > "$OUT/normalized/objc-class-names.txt"

{
  awk '/[+-]\[/ {for (i=1;i<=NF;i++) if ($i ~ /^[+-]\[/) print substr($0,index($0,$i))}' "$OUT/raw/dyld_info-objc.txt" 2>/dev/null || true
  awk '/[+-]\[/ {for (i=1;i<=NF;i++) if ($i ~ /^[+-]\[/) print substr($0,index($0,$i))}' "$OUT/raw/objdump-objc-meta-data.txt" 2>/dev/null || true
  awk '$1 ~ /^[0-9a-fA-F]+$/ && $0 ~ /[+-]\[/ {print substr($0,index($0,$4))}' "$OUT/raw/nm-all.txt" 2>/dev/null || true
} | sort -u > "$OUT/normalized/objc-methods.txt"

{
  awk -F': ' '/=>/ {print $2}' "$OUT/raw/ipsw-macho-objc-refs.txt" 2>/dev/null || true
  awk '$0 ~ /^[[:space:]]*[0-9a-fA-F]+ / {s=$0; sub(/^[[:space:]]*[0-9a-fA-F]+[[:space:]]+/,"",s); if (index(s,":")) print s}' "$OUT/raw/strings-offsets.txt" 2>/dev/null || true
} | sort -u > "$OUT/normalized/objc-selectors.txt"

awk '
  $1 ~ /^[0-9a-fA-F]+$/ {
    off="0x"$1;
    s=$0;
    sub(/^[[:space:]]*[0-9a-fA-F]+[[:space:]]+/, "", s);
    print off "\t" s;
  }
' "$OUT/raw/strings-offsets.txt" > "$OUT/normalized/strings.tsv" || true

awk 'seen || /^<\?xml/ || /^<!DOCTYPE/ || /^<plist/ {seen=1; print}' "$OUT/raw/codesign-entitlements.txt" > "$OUT/normalized/entitlements.xml" || true
cp "$OUT/raw/otool-l.txt" "$OUT/normalized/load-commands.txt" 2>/dev/null || true
{
  cat "$OUT/raw/dyld_info-uuid.txt" 2>/dev/null || true
  cat "$OUT/raw/dyld_info-platform.txt" 2>/dev/null || true
  cat "$OUT/raw/dyld_info-segments.txt" 2>/dev/null || true
  cat "$OUT/raw/dyld_info-linked_dylibs.txt" 2>/dev/null || true
} > "$OUT/normalized/dyld-info-summary.txt"

{
  print -r -- "# Mach-O Static Index"
  print -r -- ""
  print -r -- "- input: \`$BIN\`"
  print -r -- "- arch used: \`$ARCH\`"
  print -r -- "- output: \`$OUT\`"
  print -r -- "- raw output: \`raw/\`"
  print -r -- "- normalized output: \`normalized/\`"
  print -r -- ""
  print -r -- "## Counts"
  print -r -- ""
  printf -- "- undefined/import symbols: %s\n" "$(wc -l < "$OUT/normalized/imports-undefined-symbols.txt" | tr -d ' ')"
  printf -- "- defined symbols: %s\n" "$(wc -l < "$OUT/normalized/defined-symbols.txt" | tr -d ' ')"
  printf -- "- ObjC classes: %s\n" "$(wc -l < "$OUT/normalized/objc-class-names.txt" | tr -d ' ')"
  printf -- "- ObjC methods: %s\n" "$(wc -l < "$OUT/normalized/objc-methods.txt" | tr -d ' ')"
  printf -- "- ObjC selectors: %s\n" "$(wc -l < "$OUT/normalized/objc-selectors.txt" | tr -d ' ')"
  printf -- "- strings: %s\n" "$(wc -l < "$OUT/normalized/strings.tsv" | tr -d ' ')"
  print -r -- ""
  print -r -- "## Tool Notes"
  print -r -- ""
  print -r -- "Optional ipsw/jtool2 probes are under \`metadata/tool-probes/\`; incompatible or killed probes are non-fatal."
} > "$OUT/summary.md"

print -r -- "$OUT"
