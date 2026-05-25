#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common_reverse.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  reverse_wrapper_funnel_map.sh [-o outdir] <26.4-root-or-mach-o> <26.5-root-or-mach-o>

Maps Packet 004 wrapper/helper funnel anchors across explicit Mach-O pairs or
artifact roots. Emits CSV and Markdown tables with addresses, likely callsites,
confidence, and raw provenance.
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

[[ $# -eq 2 ]] || usage
ROOT_264="$(reverse_abs_path "$1")"
ROOT_265="$(reverse_abs_path "$2")"
[[ -e "$ROOT_264" ]] || reverse_die "26.4 root or Mach-O not found: $ROOT_264"
[[ -e "$ROOT_265" ]] || reverse_die "26.5 root or Mach-O not found: $ROOT_265"

[[ -n "$OUT" ]] || OUT="$(reverse_default_outdir wrapper-funnel-map "$(basename "$ROOT_264")-$(basename "$ROOT_265")")"
OUT="$(reverse_abs_path "$OUT")"
reverse_mkdirs "$OUT"

TERMS=(
  "FPSandboxingURLWrapper"
  "wrapperWithURL:readonly:error:"
  "wrapperWithURL:extensionClass:error:"
  "fp_issueSandboxExtensionOfClass:report:error:"
  "sandbox_extension_issue_file"
  "_fpfs_fast_realpath"
)

RELS=(
  "System/Library/Frameworks/FileProvider.framework/Versions/A/FileProvider"
  "System/Library/PrivateFrameworks/FileProviderDaemon.framework/Versions/A/FileProviderDaemon"
  "System/Library/PrivateFrameworks/CloudDocs.framework/PlugIns/com.apple.CloudDocs.iCloudDriveFileProvider.appex/Contents/MacOS/com.apple.CloudDocs.iCloudDriveFileProvider"
)

csv_escape() {
  local value="$1"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

find_rel_under_root() {
  local root="$1"
  local rel="$2"
  local candidates=(
    "$root/$rel"
    "$root/selected/$rel"
    "$root/dyld/selected/$rel"
    "$root/file/standalone/$rel"
    "$root/standalone/$rel"
    "$root/04/dyld/selected/$rel"
    "$root/04/file/standalone/$rel"
    "$root/artifacts/dyld-members-packet004/26.5/selected/$rel"
    "$root/artifacts/packet004-fileprovider/26.5/standalone/$rel"
    "$root/dyld-members-packet004/26.5/selected/$rel"
    "$root/packet004-fileprovider/26.5/standalone/$rel"
  )
  local p
  for p in "${candidates[@]}"; do
    if [[ -f "$p" ]]; then
      print -r -- "$p"
      return
    fi
  done
}

collect_binaries() {
  local root="$1"
  if [[ -f "$root" ]]; then
    print -r -- "$root"
    return
  fi
  local rel found
  for rel in "${RELS[@]}"; do
    found="$(find_rel_under_root "$root" "$rel")"
    [[ -n "$found" ]] && print -r -- "$found"
  done
}

map_one_binary() {
  local build="$1"
  local bin="$2"
  local safe arch dir text path_hash path_slug
  path_hash="$(printf '%s' "$build:$bin" | shasum -a 1 | awk '{print substr($1,1,10)}')"
  path_slug="$(print -r -- "$build-$(basename "$bin")" | tr -cs '[:alnum:]._-' '_' | sed 's/^_//;s/_$//')"
  safe="${path_slug}-${path_hash}"
  dir="$OUT/raw/$safe"
  mkdir -p "$dir"
  arch="$(reverse_select_arch "$bin")"
  [[ -n "$arch" ]] || return 0
  print -r -- "$arch" > "$dir/arch.txt"
  print -r -- "$bin" > "$dir/input.txt"

  reverse_run_capture "$dir/nm-all.txt" nm -arch "$arch" -m "$bin"
  reverse_run_capture "$dir/nm-undefined.txt" nm -arch "$arch" -m -u "$bin"
  reverse_run_capture "$dir/strings-offsets.txt" strings -a -t x "$bin"
  reverse_run_capture "$dir/otool-Iv.txt" otool -arch "$arch" -Iv "$bin"
  if command -v dyld_info >/dev/null 2>&1; then
    reverse_run_capture "$dir/dyld_info-objc.txt" dyld_info -arch "$arch" -objc "$bin"
  fi
  if command -v objdump >/dev/null 2>&1; then
    reverse_run_capture "$dir/objdump-indirect-symbols.txt" objdump --macho --arch="$arch" --indirect-symbols "$bin"
  fi
  if command -v ipsw >/dev/null 2>&1; then
    reverse_run_capture "$dir/ipsw-macho-objc-refs.txt" ipsw macho info --arch "$arch" --objc --objc-refs "$bin"
  fi
  text="$dir/text.disass.txt"
  reverse_text_disassembly "$bin" "$arch" "$text"

  local term slug matches addr addr_note callsite confidence notes search_dir import_file stub hit page off
  for term in "${TERMS[@]}"; do
    slug="$(reverse_safe_slug "$term")"
    matches="$dir/matches-$slug.txt"
    {
      awk -v q="$term" 'index(tolower($0),tolower(q)) {print "nm-all\t" $0}' "$dir/nm-all.txt" 2>/dev/null || true
      awk -v q="$term" 'index(tolower($0),tolower(q)) {print "nm-undefined\t" $0}' "$dir/nm-undefined.txt" 2>/dev/null || true
      awk -v q="$term" 'index(tolower($0),tolower(q)) {print "strings\t" $0}' "$dir/strings-offsets.txt" 2>/dev/null || true
      awk -v q="$term" 'index(tolower($0),tolower(q)) {print "dyld-objc\t" $0}' "$dir/dyld_info-objc.txt" 2>/dev/null || true
      awk -v q="$term" 'index(tolower($0),tolower(q)) {print "indirect\t" $0}' "$dir/objdump-indirect-symbols.txt" 2>/dev/null || true
      awk -v q="$term" 'index(tolower($0),tolower(q)) {print "objc-refs\t" $0}' "$dir/ipsw-macho-objc-refs.txt" 2>/dev/null || true
      awk -v q="$term" 'index(tolower($0),tolower(q)) {print "otool-Iv\t" $0}' "$dir/otool-Iv.txt" 2>/dev/null || true
    } > "$matches"

    addr="$(awk '
      {
        for (i=1;i<=NF;i++) {
          if ($i ~ /^0x[0-9a-fA-F]+$/) {print $i; exit}
          if ($i ~ /^[0-9a-fA-F]+$/ && length($i) >= 8) {print "0x"$i; exit}
        }
      }
    ' "$matches" 2>/dev/null || true)"
    addr_note="symbol-or-ref"
    if [[ -z "$addr" ]]; then
      addr="$(awk '$1=="strings" && $2 ~ /^[0-9a-fA-F]+$/ {print "offset:0x"$2; exit}' "$matches" 2>/dev/null || true)"
      addr_note="string-offset"
    fi

    callsite=""
    notes="$addr_note"
    if [[ "$term" == *:* ]]; then
      search_dir="$dir/selector-$slug"
      reverse_selector_stubs "$bin" "$arch" "$term" "$search_dir"
      while IFS=$'\t' read -r stub selref desc; do
        [[ "$stub" == 0x* ]] || continue
        hit="$(reverse_branch_callsites_for_target "$text" "$stub" | awk -F'\t' 'NR==1 {print $1}')"
        if [[ -n "$hit" ]]; then
          callsite="$hit"
          notes="selector-stub=$stub selref=$selref"
          break
        fi
      done < "$search_dir/selector-stubs.tsv"
    fi

    if [[ -z "$callsite" ]]; then
      import_file="$dir/import-stubs-$slug.txt"
      reverse_import_stubs "$bin" "$arch" "$term" "$import_file"
      while IFS= read -r line; do
        stub="$(print -r -- "$line" | awk '$1 ~ /^0x[0-9a-fA-F]+$/ {print $1; exit}')"
        [[ "$stub" == 0x* ]] || continue
        hit="$(reverse_branch_callsites_for_target "$text" "$stub" | awk -F'\t' 'NR==1 {print $1}')"
        if [[ -n "$hit" ]]; then
          callsite="$hit"
          notes="import-stub=$stub"
          break
        fi
      done < "$import_file"
    fi

    if [[ -z "$callsite" && -n "$addr" && "$addr" == 0x* && "$term" == *"FPSandboxingURLWrapper"* ]]; then
      page="$(reverse_addr_page "$addr")"
      off="$(reverse_addr_page_off "$addr")"
      callsite="$(awk -v page="$page" -v off="#${off}" '
        /^0x[0-9a-fA-F]+:/ {addr=$1; sub(/:$/, "", addr)}
        index($0,page) {candidate=addr; next}
        candidate != "" && index($0,off) {print candidate; exit}
      ' "$text")"
      [[ -n "$callsite" ]] && notes="class-or-got-ref=$addr"
    fi

    if [[ -n "$callsite" ]]; then
      confidence="high"
    elif [[ -n "$addr" && "$addr" != offset:* ]]; then
      confidence="medium"
    elif [[ -n "$addr" ]]; then
      confidence="low"
    else
      confidence="none"
      notes="not found"
    fi

    {
      csv_escape "$build"; printf ","
      csv_escape "$bin"; printf ","
      csv_escape "$term"; printf ","
      csv_escape "$addr"; printf ","
      csv_escape "$callsite"; printf ","
      csv_escape "$confidence"; printf ","
      csv_escape "$notes"; printf "\n"
    } >> "$OUT/normalized/wrapper-funnel-map.csv"
  done
}

{
  print -r -- '"build","binary","symbol_or_string","address_or_offset","callsite_address","confidence","notes"'
} > "$OUT/normalized/wrapper-funnel-map.csv"

PROGRESS_OUT="$OUT/raw/wrapper-map-progress.stdout.txt"
PROGRESS_ERR="$OUT/raw/wrapper-map-progress.stderr.txt"
: > "$PROGRESS_OUT"
: > "$PROGRESS_ERR"

collect_binaries "$ROOT_264" | while IFS= read -r bin; do
  map_one_binary "26.4" "$bin" >> "$PROGRESS_OUT" 2>> "$PROGRESS_ERR"
done
collect_binaries "$ROOT_265" | while IFS= read -r bin; do
  map_one_binary "26.5" "$bin" >> "$PROGRESS_OUT" 2>> "$PROGRESS_ERR"
done

{
  print -r -- "# Packet 004 Wrapper Funnel Map"
  print -r -- ""
  print -r -- "- 26.4 input: \`$ROOT_264\`"
  print -r -- "- 26.5 input: \`$ROOT_265\`"
  print -r -- "- output: \`$OUT\`"
  print -r -- ""
  print -r -- "| build | binary | symbol/string | address/offset | callsite | confidence | notes |"
  print -r -- "|---|---|---|---|---|---|---|"
  awk -F',' '
    NR > 1 {
      for (i=1;i<=NF;i++) {
        gsub(/^"/,"",$i); gsub(/"$/,"",$i); gsub(/""/,"\"",$i); gsub(/\|/,"\\|",$i);
      }
      n=$2; sub(/^.*\//,"",n);
      print "| " $1 " | `" n "` | `" $3 "` | `" $4 "` | `" $5 "` | " $6 " | " $7 " |";
    }
  ' "$OUT/normalized/wrapper-funnel-map.csv"
  print -r -- ""
  print -r -- "Raw per-binary command output is under \`raw/\`."
} > "$OUT/summary.md"

print -r -- "$OUT"
