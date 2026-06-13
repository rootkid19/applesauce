#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  collect_f022_iomfb_kc_artifacts.sh <label> [root]

example:
  tools/collect_f022_iomfb_kc_artifacts.sh m1max-26.5.1 /

Read-only collector for F022 IOMobileFramebuffer/IOSurface kernelcache
structural pre-check artifacts. This script copies kernel collections and
derives static metadata only; it does not make IOConnect calls, load or unload
kexts, change boot-args, or change SIP.
EOF
  exit 2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
fi

LABEL="$1"
ROOT_INPUT="${2:-/}"

if [[ -z "$LABEL" || "$LABEL" == "." || "$LABEL" == ".." || "$LABEL" == *"/"* ]]; then
  echo "label is required and must not be '.', '..', or contain '/'" >&2
  exit 2
fi

if [[ ! -d "$ROOT_INPUT" ]]; then
  echo "root not found: $ROOT_INPUT" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APPLESAUCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ROOT="$(cd "$ROOT_INPUT" && pwd -P)"
OUT="$APPLESAUCE_ROOT/artifacts/F022-iomfb-kc-artifacts/$LABEL"
META="$OUT/metadata"
KCS="$OUT/kernelcollections"
EXTRACTED="$OUT/extracted"
REVERSE="$OUT/reverse"
COPY_ERRORS="$META/copy-errors.txt"

if [[ -e "$OUT" && -n "$(find "$OUT" -mindepth 1 -print -quit 2>/dev/null || true)" ]]; then
  if [[ "${APPLESAUCE_OVERWRITE:-0}" != "1" ]]; then
    cat >&2 <<EOF
output already exists and is non-empty: $OUT

Use a fresh label, or rerun with:
  APPLESAUCE_OVERWRITE=1 $0 $LABEL $ROOT
EOF
    exit 2
  fi
  rm -rf "$OUT"
fi

mkdir -p "$META" "$KCS" "$EXTRACTED" "$REVERSE"
: > "$COPY_ERRORS"

echo "[*] label: $LABEL"
echo "[*] root: $ROOT"
echo "[*] out: $OUT"

root_join() {
  local rel="$1"
  rel="${rel#/}"
  if [[ "$ROOT" == "/" ]]; then
    printf '/%s\n' "$rel"
  else
    printf '%s/%s\n' "$ROOT" "$rel"
  fi
}

safe_name() {
  local value="$1"
  value="${value#/}"
  value="${value//\//__}"
  printf '%s\n' "$value"
}

append_cmd() {
  local out="$1"
  shift
  {
    printf '\n== %s ==\n' "$*"
    printf 'command:'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
    local rc=$?
    printf '\n[exit_status=%s]\n' "$rc"
  } >> "$out" 2>&1
}

append_bounded_cmd() {
  local out="$1"
  local seconds="$2"
  shift 2
  {
    printf '\n== %s ==\n' "$*"
    printf 'command:'
    printf ' %q' "$@"
    printf '\n'
    printf 'timeout_seconds=%s\n\n' "$seconds"
  } >> "$out" 2>&1

  (
    "$@"
  ) >> "$out" 2>&1 &
  local pid=$!
  (
    sleep "$seconds"
    kill -TERM "$pid" >/dev/null 2>&1 || true
    sleep 2
    kill -KILL "$pid" >/dev/null 2>&1 || true
  ) &
  local killer=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$killer" >/dev/null 2>&1 || true
  wait "$killer" 2>/dev/null || true
  printf '\n[exit_status=%s]\n' "$rc" >> "$out"
}

run_capture() {
  local stdout="$1"
  local stderr="$2"
  shift 2
  {
    printf 'command:'
    printf ' %q' "$@"
    printf '\n'
    printf 'date_utc=%s\n\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } > "$stdout"
  {
    printf 'command:'
    printf ' %q' "$@"
    printf '\n'
    printf 'date_utc=%s\n\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } > "$stderr"
  "$@" >> "$stdout" 2>> "$stderr"
  local rc=$?
  printf '\n[exit_status=%s]\n' "$rc" >> "$stdout"
  printf '\n[exit_status=%s]\n' "$rc" >> "$stderr"
  return "$rc"
}

run_stdout_capture() {
  local out="$1"
  local stderr="$2"
  shift 2
  "$@" > "$out" 2> "$stderr"
  local rc=$?
  printf '%s\n' "$rc" > "${stderr%.txt}.status.txt"
  return "$rc"
}

run_nm_capture() {
  local bin="$1"
  local out="$2"
  local base="$3"
  local stderr="$META/$base.nm.stderr.txt"
  {
    printf 'command: nm -nm %q | c++filt\n' "$bin"
    printf 'date_utc=%s\n\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } > "$stderr"
  if ! command -v nm >/dev/null 2>&1; then
    echo "missing nm" >> "$stderr"
    echo "127" > "$META/$base.nm.status.txt"
    return 0
  fi
  if ! command -v c++filt >/dev/null 2>&1; then
    echo "missing c++filt" >> "$stderr"
    echo "127" > "$META/$base.nm.status.txt"
    return 0
  fi
  (nm -nm "$bin" 2>> "$stderr" | c++filt > "$out" 2>> "$stderr")
  local rc=$?
  printf '%s\n' "$rc" > "$META/$base.nm.status.txt"
  if [[ $rc -ne 0 ]]; then
    printf '[nm pipeline exit_status=%s]\n' "$rc" >> "$stderr"
  fi
  return 0
}

capture_context() {
  local out="$META/collection-context.txt"
  : > "$out"
  {
    printf 'label=%s\n' "$LABEL"
    printf 'root=%s\n' "$ROOT"
    printf 'out=%s\n' "$OUT"
    printf 'script=%s\n' "$0"
  } >> "$out"
  append_cmd "$out" date -u
  append_cmd "$out" sw_vers
  append_cmd "$out" uname -a
  append_cmd "$out" sysctl kern.osversion kern.version hw.model hw.machine
  if command -v system_profiler >/dev/null 2>&1; then
    append_bounded_cmd "$out" 30 system_profiler SPHardwareDataType
  else
    printf '\n== system_profiler SPHardwareDataType ==\nmissing system_profiler\n' >> "$out"
  fi
  if command -v kmutil >/dev/null 2>&1; then
    append_bounded_cmd "$out" 30 kmutil showloaded
    append_bounded_cmd "$out" 45 kmutil inspect
    append_bounded_cmd "$out" 45 kmutil inspect --volume-root "$ROOT"
  else
    printf '\n== kmutil showloaded ==\nmissing kmutil\n' >> "$out"
    printf '\n== kmutil inspect ==\nmissing kmutil\n' >> "$out"
    printf '\n== kmutil inspect --volume-root %s ==\nmissing kmutil\n' "$ROOT" >> "$out"
  fi
}

capture_tool_probes() {
  local out="$META/tool-probes.txt"
  local tool
  : > "$out"
  for tool in date sw_vers uname sysctl system_profiler kmutil ipsw nm c++filt xcrun shasum file cp find sort stat; do
    {
      printf '\n== command -v %s ==\n' "$tool"
      command -v "$tool" || true
    } >> "$out" 2>&1
  done
  if command -v ipsw >/dev/null 2>&1; then
    append_cmd "$out" ipsw version
    append_cmd "$out" ipsw kernel extract --help
    append_cmd "$out" ipsw kernel kexts --help
    append_cmd "$out" ipsw img4 extract --help
    append_cmd "$out" ipsw img4 im4p extract --help
  fi
  if command -v xcrun >/dev/null 2>&1; then
    append_cmd "$out" xcrun --find llvm-objdump
    append_cmd "$out" xcrun llvm-objdump --version
  fi
}

copy_kc() {
  local rel="$1"
  local optional="$2"
  local src dst base
  src="$(root_join "$rel")"
  base="$(basename "$rel")"
  dst="$KCS/$base"

  {
    printf 'path=%s\n' "$rel"
    printf 'source=%s\n' "$src"
    if [[ -e "$src" || -L "$src" ]]; then
      ls -laeO@ "$src" || true
      file "$src" || true
    else
      if [[ "$optional" == "yes" ]]; then
        echo "optional_absent"
      else
        echo "missing"
      fi
    fi
  } > "$META/$base.file.txt" 2>&1

  if [[ ! -f "$src" ]]; then
    if [[ "$optional" == "yes" ]]; then
      printf 'optional absent: %s\n' "$src" >> "$COPY_ERRORS"
    else
      printf 'missing: %s\n' "$src" >> "$COPY_ERRORS"
    fi
    return 0
  fi

  if cp "$src" "$dst" 2>> "$COPY_ERRORS"; then
    printf '%s\n' "$dst" >> "$META/copied-kernelcollections.txt"
    shasum -a 256 "$dst" > "$META/$base.sha256" 2>&1 || true
  else
    printf 'copy failed: %s -> %s\n' "$src" "$dst" >> "$COPY_ERRORS"
  fi
}

copy_preboot_kernelcache() {
  local src="$1"
  local idx="$2"
  local tag img4 macho work im4p
  tag="PrebootKernelCache-$idx"
  img4="$KCS/$tag.img4"
  macho="$KCS/$tag.macho"

  {
    printf 'path=%s\n' "$src"
    printf 'source=%s\n' "$src"
    if [[ -e "$src" || -L "$src" ]]; then
      ls -laeO@ "$src" || true
      file "$src" || true
    else
      echo "missing"
    fi
  } > "$META/$tag.img4.file.txt" 2>&1

  if [[ ! -f "$src" ]]; then
    printf 'missing preboot kernelcache: %s\n' "$src" >> "$COPY_ERRORS"
    return 0
  fi

  if cp "$src" "$img4" 2>> "$COPY_ERRORS"; then
    printf '%s\n' "$img4" >> "$META/copied-kernelcollections.txt"
    shasum -a 256 "$img4" > "$META/$tag.img4.sha256" 2>&1 || true
  else
    printf 'copy failed: %s -> %s\n' "$src" "$img4" >> "$COPY_ERRORS"
    return 0
  fi

  if ! command -v ipsw >/dev/null 2>&1; then
    echo "ipsw missing; cannot unwrap $img4" > "$META/$tag.unwrap-skipped.txt"
    return 0
  fi

  work="$(mktemp -d "${TMPDIR:-/tmp}/f022-preboot-img4.XXXXXX" 2>/dev/null || mktemp -d "/tmp/f022-preboot-img4.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$work" || ! -d "$work" ]]; then
    printf 'failed to create temporary IMG4 directory for %s\n' "$img4" > "$META/$tag.unwrap-skipped.txt"
    return 0
  fi

  if run_capture "$META/$tag.img4-extract.stdout.txt" "$META/$tag.img4-extract.stderr.txt" \
      ipsw --no-color img4 extract --im4p --output "$work" "$img4"; then
    im4p="$(find "$work" -type f -name '*.im4p' -print -quit 2>/dev/null || true)"
    if [[ -n "$im4p" && -f "$im4p" ]]; then
      run_capture "$META/$tag.im4p-extract.stdout.txt" "$META/$tag.im4p-extract.stderr.txt" \
        ipsw --no-color img4 im4p extract --output "$macho" "$im4p" || true
    else
      printf 'no IM4P output found under %s\n' "$work" > "$META/$tag.im4p-extract.stderr.txt"
    fi
  fi

  if [[ -f "$macho" ]]; then
    printf '%s\n' "$macho" >> "$META/copied-kernelcollections.txt"
    file "$macho" > "$META/$tag.macho.file.txt" 2>&1 || true
    shasum -a 256 "$macho" > "$META/$tag.macho.sha256" 2>&1 || true
  fi

  rm -rf "$work"
}

collect_preboot_kernelcaches() {
  local preboot_root candidates_file candidates_tsv sorted_tsv idx limit src mtime
  preboot_root=""
  if [[ "$ROOT" == "/" ]]; then
    preboot_root="/System/Volumes/Preboot"
  elif [[ -d "$ROOT/System/Volumes/Preboot" ]]; then
    preboot_root="$ROOT/System/Volumes/Preboot"
  fi

  candidates_file="$META/preboot-kernelcache-candidates.txt"
  candidates_tsv="$META/preboot-kernelcache-candidates.tsv"
  sorted_tsv="$META/preboot-kernelcache-candidates.sorted.tsv"
  : > "$candidates_file"
  : > "$candidates_tsv"
  : > "$sorted_tsv"

  if [[ -z "$preboot_root" || ! -d "$preboot_root" ]]; then
    echo "preboot root not found" >> "$candidates_file"
    return 0
  fi

  for src in "$preboot_root"/*/boot/*/System/Library/Caches/com.apple.kernelcaches/kernelcache; do
    [[ -f "$src" ]] || continue
    printf '%s\n' "$src" >> "$candidates_file"
    mtime="$(stat -f '%m' "$src" 2>/dev/null || echo 0)"
    printf '%s\t%s\n' "$mtime" "$src" >> "$candidates_tsv"
  done

  LC_ALL=C sort -k1,1rn -k2,2 "$candidates_tsv" > "$sorted_tsv" 2>/dev/null || true
  idx=0
  limit="${APPLESAUCE_PREBOOT_KC_LIMIT:-3}"
  if [[ -z "$limit" || "$limit" == *[!0-9]* ]]; then
    printf 'invalid APPLESAUCE_PREBOOT_KC_LIMIT=%q; using 3\n' "$limit" >> "$COPY_ERRORS"
    limit=3
  fi
  while IFS="$(printf '\t')" read -r mtime src; do
    [[ -n "$src" && -f "$src" ]] || continue
    idx=$((idx + 1))
    if [[ "$idx" -gt "$limit" ]]; then
      printf 'skipped due to APPLESAUCE_PREBOOT_KC_LIMIT=%s: %s\n' "$limit" "$src" >> "$COPY_ERRORS"
      continue
    fi
    printf '[*] copying preboot kernelcache %02d: %s\n' "$idx" "$src"
    copy_preboot_kernelcache "$src" "$(printf '%02d' "$idx")"
  done < "$sorted_tsv"

  if [[ "$idx" -eq 0 ]]; then
    echo "no preboot boot/* kernelcache candidates found" >> "$candidates_file"
  fi
}

find_extracted_candidate() {
  local dir="$1"
  local target="$2"
  local candidate
  candidate="$(find "$dir" -type f -name "$target" -print -quit 2>/dev/null || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate="$(find "$dir" -type f -path "*$target*" -print -quit 2>/dev/null || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate="$(find "$dir" -type f -print -quit 2>/dev/null || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
  fi
}

attempt_extract_one() {
  local kc="$1"
  local target="$2"
  local kcbase target_safe work stdout stderr status files candidate
  kcbase="$(basename "$kc")"
  target_safe="$(safe_name "$target")"
  work="$(mktemp -d "${TMPDIR:-/tmp}/f022-kc-extract.XXXXXX" 2>/dev/null || mktemp -d "/tmp/f022-kc-extract.XXXXXX" 2>/dev/null || true)"
  stdout="$META/extract-$kcbase-$target_safe.stdout.txt"
  stderr="$META/extract-$kcbase-$target_safe.stderr.txt"
  status="$META/extract-$kcbase-$target_safe.status.txt"
  files="$META/extract-$kcbase-$target_safe.files.txt"

  if [[ -z "$work" || ! -d "$work" ]]; then
    printf 'failed to create temporary extraction directory for %s from %s\n' "$target" "$kcbase" >> "$META/extraction-summary.txt"
    return 1
  fi

  run_capture "$META/kexts-$kcbase.stdout.txt" "$META/kexts-$kcbase.stderr.txt" \
    ipsw --no-color kernel kexts "$kc" >/dev/null 2>&1 || true

  run_capture "$stdout" "$stderr" \
    ipsw --no-color kernel extract "$kc" "$target" --arch arm64e --imports --force --output "$work"
  local rc=$?
  printf '%s\n' "$rc" > "$status"
  find "$work" -type f -print > "$files" 2>&1 || true
  if [[ $rc -ne 0 ]]; then
    rm -rf "$work"
    return 1
  fi

  candidate="$(find_extracted_candidate "$work" "$target")"
  if [[ -z "$candidate" || ! -f "$candidate" ]]; then
    printf 'extract command succeeded but no fileset candidate found for %s in %s\n' "$target" "$work" >> "$META/extraction-summary.txt"
    rm -rf "$work"
    return 1
  fi

  if cp "$candidate" "$EXTRACTED/$target" 2>> "$META/extract-copy-errors.txt"; then
    {
      printf 'target=%s\n' "$target"
      printf 'kernelcollection=%s\n' "$kcbase"
      printf 'candidate=%s\n' "$candidate"
      printf 'output=%s\n' "$EXTRACTED/$target"
    } >> "$META/extraction-summary.txt"
    rm -rf "$work"
    return 0
  fi

  printf 'failed to copy extracted candidate for %s: %s\n' "$target" "$candidate" >> "$META/extraction-summary.txt"
  rm -rf "$work"
  return 1
}

extract_targets() {
  local targets=(
    "com.apple.iokit.IOMobileGraphicsFamily"
    "com.apple.iokit.IOSurface"
  )
  local target kc found
  : > "$META/extraction-summary.txt"
  if ! command -v ipsw >/dev/null 2>&1; then
    {
      echo "ipsw missing; extraction skipped."
      echo "Copied kernel collections remain under kernelcollections/."
    } >> "$META/extraction-summary.txt"
    return 0
  fi

  for target in "${targets[@]}"; do
    found="no"
    for kc in "$KCS"/PrebootKernelCache-*.macho "$KCS"/BootKernelExtensions.kc "$KCS"/SystemKernelExtensions.kc "$KCS"/AuxiliaryKernelExtensions.kc; do
      [[ -f "$kc" ]] || continue
      echo "[*] extracting $target from $(basename "$kc")"
      if attempt_extract_one "$kc" "$target"; then
        found="yes"
        break
      fi
    done
    if [[ "$found" != "yes" ]]; then
      printf 'failed: %s\n' "$target" >> "$META/extraction-summary.txt"
    fi
  done
}

reverse_one() {
  local target="$1"
  local short="$2"
  local bin="$EXTRACTED/$target"
  [[ -f "$bin" ]] || return 0

  echo "[*] reversing $target"
  file "$bin" > "$META/$short.file.txt" 2>&1 || true
  shasum -a 256 "$bin" > "$META/$short.sha256" 2>&1 || true

  run_nm_capture "$bin" "$REVERSE/$short.nm.txt" "reverse-$short" || true

  if command -v xcrun >/dev/null 2>&1 && xcrun --find llvm-objdump >/dev/null 2>&1; then
    run_stdout_capture "$REVERSE/$short.symbols.txt" "$META/reverse-$short.symbols.stderr.txt" \
      xcrun llvm-objdump --macho --syms --arch=arm64e "$bin" || true
    run_stdout_capture "$REVERSE/$short.disass.txt" "$META/reverse-$short.disass.stderr.txt" \
      xcrun llvm-objdump --macho --disassemble --arch=arm64e --symbolize-operands "$bin" || true
  else
    echo "missing xcrun llvm-objdump" > "$META/reverse-$short.llvm-objdump-missing.txt"
  fi
}

generate_reverse_artifacts() {
  reverse_one "com.apple.iokit.IOMobileGraphicsFamily" "IOMobileGraphicsFamily"
  reverse_one "com.apple.iokit.IOSurface" "IOSurface"
}

write_hashes() {
  local hashes="$META/hashes.sha256"
  (
    cd "$OUT" || exit 0
    find kernelcollections extracted reverse -type f -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r path; do
      shasum -a 256 "$path"
    done
  ) > "$hashes" 2>&1 || true
}

capture_context
capture_tool_probes

copy_kc "System/Library/KernelCollections/BootKernelExtensions.kc" "no"
copy_kc "System/Library/KernelCollections/SystemKernelExtensions.kc" "no"
copy_kc "System/Library/KernelCollections/AuxiliaryKernelExtensions.kc" "yes"
collect_preboot_kernelcaches

extract_targets
generate_reverse_artifacts
write_hashes

echo "$OUT"
