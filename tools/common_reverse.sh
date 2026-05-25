#!/bin/zsh
set -euo pipefail

REVERSE_TOOLS_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
if [[ -f "$REVERSE_TOOLS_DIR/common.sh" ]]; then
  source "$REVERSE_TOOLS_DIR/common.sh"
fi

reverse_die() {
  echo "$*" >&2
  exit 2
}

reverse_abs_path() {
  local input_path="$1"
  print -r -- "${input_path:A}"
}

reverse_safe_slug() {
  local value="$1"
  value="$(basename "$value")"
  value="$(print -r -- "$value" | tr -cs '[:alnum:]._-' '_' | sed 's/^_//;s/_$//')"
  [[ -n "$value" ]] || value="macho"
  print -r -- "$value"
}

reverse_timestamp() {
  if [[ -n "${APPLESAUCE_REVERSE_TIMESTAMP:-}" ]]; then
    print -r -- "$APPLESAUCE_REVERSE_TIMESTAMP"
  elif typeset -f timestamp_utc >/dev/null 2>&1; then
    timestamp_utc
  else
    date -u +"%Y%m%d-%H%M%SZ"
  fi
}

reverse_artifact_root() {
  if typeset -f artifact_root >/dev/null 2>&1; then
    artifact_root
  else
    local root
    root="$(cd "$REVERSE_TOOLS_DIR/../.." && pwd)/artifacts"
    mkdir -p "$root"
    print -r -- "$root"
  fi
}

reverse_default_outdir() {
  local kind="$1"
  local input="$2"
  local root slug ts
  root="$(reverse_artifact_root)"
  slug="$(reverse_safe_slug "$input")"
  ts="$(reverse_timestamp)"
  print -r -- "$root/static-re/$kind/$ts-$slug"
}

reverse_mkdirs() {
  local out="$1"
  mkdir -p "$out"/{raw,normalized,metadata,slices}
}

reverse_cmd_path() {
  command -v "$1" 2>/dev/null || true
}

reverse_run_capture() {
  local out="$1"
  shift
  mkdir -p "$(dirname "$out")"
  set +e
  {
    print -r -- "command: $*"
    print -r -- "date_utc: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    print -r -- ""
    "$@"
  } > "$out" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    print -r -- "" >> "$out"
    print -r -- "[exit_status=$rc]" >> "$out"
  fi
  return 0
}

reverse_run_shell_capture() {
  local out="$1"
  local desc="$2"
  local script="$3"
  mkdir -p "$(dirname "$out")"
  set +e
  {
    print -r -- "command: $desc"
    print -r -- "date_utc: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    print -r -- ""
    /bin/zsh -c "$script"
  } > "$out" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    print -r -- "" >> "$out"
    print -r -- "[exit_status=$rc]" >> "$out"
  fi
  return 0
}

reverse_probe_capture() {
  local out_prefix="$1"
  local seconds="$2"
  shift 2
  mkdir -p "$(dirname "$out_prefix")"
  {
    print -r -- "command: $*"
    print -r -- "timeout_seconds: $seconds"
  } > "$out_prefix.probe.txt"
  (
    "$@" > "$out_prefix.stdout.txt" 2> "$out_prefix.stderr.txt" &
    local pid=$!
    (
      sleep "$seconds"
      kill -9 "$pid" >/dev/null 2>&1 || true
    ) &
    local killer=$!
    wait "$pid"
    local rc=$?
    kill "$killer" >/dev/null 2>&1 || true
    print -r -- "$rc" > "$out_prefix.status.txt"
  ) >/dev/null 2>&1 || true
}

reverse_tool_inventory() {
  local out="$1"
  mkdir -p "$out/metadata/tool-probes"
  local tools=(otool nm objdump strings dyld_info lipo vtool codesign plutil dwarfdump atos xcrun ipsw jtool2)
  local tool
  for tool in "${tools[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      command -v "$tool" > "$out/metadata/tool-probes/$tool.path.txt" 2>&1 || true
    else
      print -r -- "missing" > "$out/metadata/tool-probes/$tool.path.txt"
    fi
  done
  if command -v ipsw >/dev/null 2>&1; then
    reverse_probe_capture "$out/metadata/tool-probes/ipsw-version" 4 ipsw version
    reverse_probe_capture "$out/metadata/tool-probes/ipsw-macho-help" 4 ipsw macho --help
  fi
  if command -v jtool2 >/dev/null 2>&1; then
    reverse_probe_capture "$out/metadata/tool-probes/jtool2-version" 4 jtool2 --version
    reverse_probe_capture "$out/metadata/tool-probes/jtool2-help" 4 jtool2 -h
  fi
}

reverse_select_arch() {
  local bin="$1"
  local archs=""
  if command -v lipo >/dev/null 2>&1; then
    archs="$(lipo -archs "$bin" 2>/dev/null || true)"
  fi
  if [[ -z "$archs" ]]; then
    archs="$(file "$bin" 2>/dev/null | sed -n 's/.*Mach-O .* \(arm64e\|arm64\|x86_64\).*/\1/p' | head -1)"
  fi
  local desired
  for desired in arm64e arm64; do
    if [[ " $archs " == *" $desired "* ]]; then
      print -r -- "$desired"
      return
    fi
  done
  if [[ -n "$archs" ]]; then
    print -r -- "$archs" | awk '{print $1}'
  else
    print -r -- ""
  fi
}

reverse_is_hex() {
  [[ "$1" == 0x[0-9a-fA-F]## || "$1" == [0-9a-fA-F]## ]]
}

reverse_hex_to_dec() {
  local h="$1"
  h="${h#0x}"
  h="${h#0X}"
  [[ -n "$h" ]] || h="0"
  print -r -- $(( 16#$h ))
}

reverse_dec_to_hex() {
  local d="$1"
  printf "0x%x\n" "$d"
}

reverse_addr_page() {
  local d
  d="$(reverse_hex_to_dec "$1")"
  reverse_dec_to_hex $(( d & ~4095 ))
}

reverse_addr_page_off() {
  local d
  d="$(reverse_hex_to_dec "$1")"
  reverse_dec_to_hex $(( d & 4095 ))
}

reverse_hex_sub() {
  local a b
  a="$(reverse_hex_to_dec "$1")"
  b="$(reverse_hex_to_dec "$2")"
  reverse_dec_to_hex $(( a - b ))
}

reverse_hex_add_dec() {
  local a="$1"
  local b="$2"
  a="$(reverse_hex_to_dec "$a")"
  local v=$(( a + b ))
  if [[ $v -lt 0 ]]; then
    v=0
  fi
  reverse_dec_to_hex "$v"
}

reverse_addr_to_offset() {
  local bin="$1"
  local arch="$2"
  local addr="$3"
  if command -v ipsw >/dev/null 2>&1; then
    ipsw macho a2o --arch "$arch" --hex "$bin" "$addr" 2>/dev/null | head -1 || true
  fi
}

reverse_offset_to_addr() {
  local bin="$1"
  local arch="$2"
  local off="$3"
  if command -v ipsw >/dev/null 2>&1; then
    ipsw macho o2a --arch "$arch" --hex "$bin" "$off" 2>/dev/null | head -1 || true
  fi
}

reverse_resolve_hint() {
  local bin="$1"
  local arch="$2"
  local hint="$3"
  if reverse_is_hex "$hint"; then
    [[ "$hint" == 0x* || "$hint" == 0X* ]] && print -r -- "$hint" || print -r -- "0x$hint"
    return
  fi

  local addr
  addr="$(nm -arch "$arch" -m "$bin" 2>/dev/null | awk -v q="$hint" 'index($0,q) && $1 ~ /^[0-9a-fA-F]+$/ {print "0x"$1; exit}' || true)"
  if [[ -n "$addr" ]]; then
    print -r -- "$addr"
    return
  fi

  if command -v dyld_info >/dev/null 2>&1; then
    addr="$(dyld_info -objc -arch "$arch" "$bin" 2>/dev/null | awk -v q="$hint" 'index($0,q) {for (i=1;i<=NF;i++) if ($i ~ /^0x[0-9a-fA-F]+$/) {print $i; exit}}' || true)"
    if [[ -n "$addr" ]]; then
      print -r -- "$addr"
      return
    fi
  fi

  if command -v objdump >/dev/null 2>&1; then
    addr="$(objdump --macho --arch="$arch" --function-starts=both "$bin" 2>/dev/null | awk -v q="$hint" 'index($0,q) && $1 ~ /^0x[0-9a-fA-F]+$/ {print $1; exit}' || true)"
    if [[ -n "$addr" ]]; then
      print -r -- "$addr"
      return
    fi
  fi

  if [[ "$hint" == *:* ]] && command -v ipsw >/dev/null 2>&1; then
    local selref page off
    selref="$(ipsw macho info --arch "$arch" --objc --objc-refs "$bin" 2>/dev/null | awk -v q="$hint" 'index($0,q) && $1 ~ /^0x[0-9a-fA-F]+$/ {print $1; exit}' || true)"
    if [[ "$selref" == 0x* ]]; then
      page="$(reverse_addr_page "$selref")"
      off="$(reverse_addr_page_off "$selref")"
      addr="$(ipsw macho disass --arch "$arch" --section __TEXT.__objc_stubs --quiet "$bin" 2>/dev/null | awk -v page="$page" -v off="#${off}" '
        /^0x[0-9a-fA-F]+:/ {
          candidate=$1;
          sub(/:$/, "", candidate);
        }
        index($0,page) { seen=candidate; next; }
        seen != "" && index($0,off) { print seen; exit; }
      ' || true)"
      if [[ -n "$addr" ]]; then
        print -r -- "$addr"
        return
      fi
    fi
  fi

  print -r -- ""
}

reverse_neighbor_labels() {
  local bin="$1"
  local arch="$2"
  local addr="$3"
  local out="$4"
  local target
  target="$(printf "%016x" "$(reverse_hex_to_dec "$addr")")"
  nm -arch "$arch" -m "$bin" 2>/dev/null \
    | awk -v t="$target" '
      $1 ~ /^[0-9a-fA-F]+$/ {
        h=tolower($1);
        while (length(h) < 16) h="0"h;
        if (h <= t) {
          prev=$0;
          next;
        }
        print "previous: " prev;
        print "next: " $0;
        exit;
      }
    ' > "$out" || true
}

reverse_disassemble_slice() {
  local bin="$1"
  local arch="$2"
  local start_addr="$3"
  local count="$4"
  local out="$5"
  mkdir -p "$(dirname "$out")"
  if command -v ipsw >/dev/null 2>&1; then
    {
      print -r -- "command: ipsw macho disass --arch $arch --vaddr $start_addr --count $count --quiet $bin"
      print -r -- ""
      ipsw macho disass --arch "$arch" --vaddr "$start_addr" --count "$count" --quiet "$bin"
    } > "$out" 2>&1 && return 0
  fi

  local stop_addr
  stop_addr="$(reverse_hex_add_dec "$start_addr" $(( count * 4 )))"
  local start_dec stop_dec
  start_dec="$(reverse_hex_to_dec "$start_addr")"
  stop_dec="$(reverse_hex_to_dec "$stop_addr")"
  {
    print -r -- "command: otool -arch $arch -tvV $bin | address-filter $start_addr..$stop_addr"
    print -r -- ""
    otool -arch "$arch" -tvV "$bin" 2>/dev/null | awk -v s="$start_dec" -v e="$stop_dec" '
      /^[0-9a-fA-F]+[[:space:]]/ {
        h=$1; dec=0;
        for (i=1; i<=length(h); i++) {
          c=substr(h,i,1);
          v=index("0123456789abcdef", tolower(c))-1;
          dec=dec*16+v;
        }
        if (dec >= s && dec < e) print;
        next;
      }
      /^[+-]\[/ { print; next; }
      /:$/ { print; next; }
    '
  } > "$out" 2>&1 || true
}

reverse_normalize_disassembly() {
  local in="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"
  awk '
    /^0x[0-9a-fA-F]+:/ {
      rest=$0;
      sub(/^0x[0-9a-fA-F]+:[[:space:]]+/, "", rest);
      sub(/^([0-9a-fA-F][0-9a-fA-F][[:space:]]+){4}/, "", rest);
      printf("+0x%04x: %s\n", idx*4, rest);
      idx++;
      next;
    }
    /^[0-9a-fA-F]+[[:space:]]/ {
      rest=$0;
      sub(/^[0-9a-fA-F]+[[:space:]]+/, "", rest);
      printf("+0x%04x: %s\n", idx*4, rest);
      idx++;
      next;
    }
    /^command:/ || /^date_utc:/ || /^$/ { next; }
    { print; }
  ' "$in" > "$out"
}

reverse_context_for_pattern() {
  local input="$1"
  local pattern="$2"
  local before="${3:-10}"
  local after="${4:-16}"
  awk -v q="$pattern" -v b="$before" -v a="$after" '
    {
      ring[NR % b]=$0;
      if (index(tolower($0), tolower(q))) {
        print "---- match line " NR " pattern " q " ----";
        for (i=b-1; i>=1; i--) {
          n=NR-i;
          if (n > 0) {
            k=n % b;
            if (ring[k] != "") print ring[k];
          }
        }
        print $0;
        tail=a;
        next;
      }
      if (tail > 0) {
        print $0;
        tail--;
      }
    }
  ' "$input"
}

reverse_selector_stubs() {
  local bin="$1"
  local arch="$2"
  local query="$3"
  local outdir="$4"
  mkdir -p "$outdir"

  if ! command -v ipsw >/dev/null 2>&1; then
    : > "$outdir/selector-refs.txt"
    : > "$outdir/objc-stubs.disass.txt"
    : > "$outdir/selector-stubs.tsv"
    return 0
  fi

  ipsw macho info --arch "$arch" --objc --objc-refs "$bin" > "$outdir/objc-refs.raw.txt" 2>&1 || true
  awk -v q="$query" 'index($0,q) && $1 ~ /^0x[0-9a-fA-F]+$/ {print}' "$outdir/objc-refs.raw.txt" > "$outdir/selector-refs.txt" || true
  ipsw macho disass --arch "$arch" --section __TEXT.__objc_stubs --quiet "$bin" > "$outdir/objc-stubs.disass.txt" 2>&1 || true

  : > "$outdir/selector-stubs.tsv"
  local selref page off
  while IFS= read -r line; do
    selref="$(print -r -- "$line" | awk '{print $1}')"
    [[ "$selref" == 0x* ]] || continue
    page="$(reverse_addr_page "$selref")"
    off="$(reverse_addr_page_off "$selref")"
    awk -v page="$page" -v off="#${off}" -v selref="$selref" -v desc="$line" '
      /^0x[0-9a-fA-F]+:/ {
        addr=$1;
        sub(/:$/, "", addr);
      }
      index($0,page) { candidate=addr; next; }
      candidate != "" && index($0,off) {
        print candidate "\t" selref "\t" desc;
        candidate="";
      }
    ' "$outdir/objc-stubs.disass.txt" >> "$outdir/selector-stubs.tsv"
  done < "$outdir/selector-refs.txt"
}

reverse_text_disassembly() {
  local bin="$1"
  local arch="$2"
  local out="$3"
  mkdir -p "$(dirname "$out")"
  if command -v ipsw >/dev/null 2>&1; then
    ipsw macho disass --arch "$arch" --section __TEXT.__text --quiet "$bin" > "$out" 2>&1 || true
  else
    otool -arch "$arch" -tvV "$bin" > "$out" 2>&1 || true
  fi
}

reverse_branch_callsites_for_target() {
  local text="$1"
  local target="$2"
  awk -v t="$target" '
    /^0x[0-9a-fA-F]+:/ && index(tolower($0), tolower(t)) && $0 ~ /[[:space:]]b(l)?[[:space:]]/ {
      addr=$1; sub(/:$/, "", addr); print addr "\t" $0;
    }
  ' "$text"
}

reverse_import_stubs() {
  local bin="$1"
  local arch="$2"
  local query="$3"
  local out="$4"
  otool -arch "$arch" -Iv "$bin" 2>/dev/null | awk -v q="$query" 'index($0,q)' > "$out" || true
}

reverse_markdown_escape() {
  print -r -- "$1" | sed 's/|/\\|/g'
}
