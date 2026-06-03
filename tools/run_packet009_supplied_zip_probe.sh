#!/bin/zsh
set -euo pipefail
setopt typeset_silent
setopt null_glob

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  local code="${1:-2}"
  cat >&2 <<'EOF'
usage:
  ./tools/run_packet009_supplied_zip_probe.sh --zip <zip> [options]

Purpose:
  Probe a supplied CVE-2026-28914 ZIP through normal LaunchServices / Archive
  Utility and record whether the extracted app bundle retains
  com.apple.quarantine. This does not launch the extracted app.

Options:
  --zip <path>                  supplied ZIP to open through Archive Utility
  --out <dir>                   override run directory
  --wait prompt                 wait for Enter after Archive Utility open
  --wait seconds                sleep after Archive Utility open
  --wait-seconds <n>            seconds for --wait seconds (default: 20)
  --no-set-quarantine           do not synthesize quarantine if the copied ZIP lacks it
  -h, --help                    show this help

Environment:
  APPLESAUCE_ARTIFACTS          override artifacts root
  APPLESAUCE_WORKSPACE          override workspace root

Defaults:
  out: <artifacts>/runtime/packet009-zip-gatekeeper/<version>-<build>-<stamp>-supplied-zip

Run from a normal Terminal while booted into the target OS. The script copies
the supplied ZIP into ~/Downloads before opening it because older Archive
Utility builds may redirect output there regardless of same-folder preferences.
EOF
  exit "$code"
}

ZIP=""
OUT_OVERRIDE=""
WAIT_MODE="prompt"
WAIT_SECONDS=20
SET_QUARANTINE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip)
      [[ $# -ge 2 ]] || usage
      ZIP="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || usage
      OUT_OVERRIDE="$2"
      shift 2
      ;;
    --wait)
      [[ $# -ge 2 ]] || usage
      WAIT_MODE="$2"
      shift 2
      ;;
    --wait-seconds)
      [[ $# -ge 2 ]] || usage
      WAIT_SECONDS="$2"
      shift 2
      ;;
    --no-set-quarantine)
      SET_QUARANTINE=0
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$ZIP" ]] || usage
[[ -f "$ZIP" ]] || { echo "missing ZIP: $ZIP" >&2; exit 2; }

case "$WAIT_MODE" in
  prompt|seconds) ;;
  *) echo "unsupported --wait mode: $WAIT_MODE" >&2; usage ;;
esac

if ! [[ "$WAIT_SECONDS" == <-> ]]; then
  echo "--wait-seconds must be an integer" >&2
  exit 2
fi

require_cmd /usr/bin/open
require_cmd /usr/bin/xattr
require_cmd /usr/bin/log
require_cmd /usr/bin/find
require_cmd /usr/bin/stat
require_cmd /usr/bin/awk
require_cmd /usr/bin/sort
require_cmd /bin/cp
require_cmd /bin/mkdir
require_cmd /bin/ls
require_cmd /usr/bin/shasum
require_cmd sw_vers

WORKSPACE="$(workspace_root)"
ARTIFACTS="$(artifact_root)"
STAMP="$(timestamp_utc)"
RUN_PARENT="$ARTIFACTS/runtime/packet009-zip-gatekeeper"
RUN_DIR="${OUT_OVERRIDE:-$RUN_PARENT/$(safe_sw_build_slug)-$STAMP-supplied-zip}"
DOWNLOAD_COPY="$HOME/Downloads/packet009-supplied-$STAMP.zip"
QVAL="0003;$(printf '%x' "$(date +%s)");Safari;Packet009Supplied"
LOG_PREDICATE='process == "Archive Utility" OR process == "ArchiveService" OR eventMessage CONTAINS[c] "quarantine" OR eventMessage CONTAINS[c] "DSQuarantine" OR eventMessage CONTAINS[c] "xattr" OR eventMessage CONTAINS[c] "ACL"'

mkdir -p "$RUN_DIR"/{input,logs,metadata,snapshots}

if [[ ! -d "$HOME/Downloads" ]]; then
  echo "missing Downloads directory: $HOME/Downloads" >&2
  exit 2
fi

prompt_or_sleep() {
  if [[ "$WAIT_MODE" == "seconds" ]]; then
    echo "[*] waiting ${WAIT_SECONDS}s for Archive Utility"
    sleep "$WAIT_SECONDS"
    return
  fi

  printf '%s\n' "[*] Wait until Archive Utility finishes extracting, then press Enter."
  printf '%s' "    Do not launch the extracted app before pressing Enter: "
  local reply
  IFS= read -r reply
}

path_snapshot() {
  local path="$1"
  local out="$2"
  {
    echo "path=$path"
    if [[ -e "$path" ]]; then
      /bin/ls -laeO@ "$path" || true
      /usr/bin/stat -f 'dev=%d ino=%i mode=%p uid=%u gid=%g size=%z mtime=%m birthtime=%B ctime=%c type=%HT' "$path" || true
      /usr/bin/xattr -l "$path" || true
    else
      echo "exists=0"
    fi
  } > "$out" 2>&1
}

record_app_candidate_table() {
  local out="$1"
  : > "$out"
  for root in "$HOME/Downloads" "$HOME/Desktop"; do
    [[ -d "$root" ]] || continue
    /usr/bin/find "$root" -maxdepth 8 -name 'CVE28914Payload.app' -print 2>/dev/null | while IFS= read -r app; do
      local birth mtime ctime exe_ctime exe
      exe="$app/Contents/MacOS/payload"
      birth="$(/usr/bin/stat -f '%B' "$app" 2>/dev/null || echo 0)"
      mtime="$(/usr/bin/stat -f '%m' "$app" 2>/dev/null || echo 0)"
      ctime="$(/usr/bin/stat -f '%c' "$app" 2>/dev/null || echo 0)"
      exe_ctime="$(/usr/bin/stat -f '%c' "$exe" 2>/dev/null || echo 0)"
      printf '%s\t%s\t%s\t%s\t%s\n' "$birth" "$mtime" "$ctime" "$exe_ctime" "$app"
    done
  done | /usr/bin/sort -nr >> "$out"
}

select_candidate_app() {
  local table="$1"
  local start_epoch="$2"
  local selected=""
  while IFS=$'\t' read -r birth mtime ctime exe_ctime path; do
    [[ -n "${path:-}" ]] || continue
    if [[ "$birth" == <-> && "$birth" -ge $((start_epoch - 5)) ]] ||
       [[ "$mtime" == <-> && "$mtime" -ge $((start_epoch - 5)) ]] ||
       [[ "$ctime" == <-> && "$ctime" -ge $((start_epoch - 5)) ]] ||
       [[ "$exe_ctime" == <-> && "$exe_ctime" -ge $((start_epoch - 5)) ]]; then
      selected="$path"
      break
    fi
  done < "$table"

  print -r -- "$selected"
}

record_recursive_app_state() {
  local app="$1"
  local out="$2"
  {
    echo "app=$app"
    if [[ -z "$app" || ! -d "$app" ]]; then
      echo "exists=0"
      return
    fi

    echo "=== bundle ==="
    /bin/ls -ldeO@ "$app" || true
    /usr/bin/xattr -l "$app" || true
    echo
    echo "=== executable ==="
    /bin/ls -ldeO@ "$app/Contents/MacOS/payload" || true
    /usr/bin/xattr -l "$app/Contents/MacOS/payload" || true
    echo
    echo "=== recursive xattrs ==="
    /usr/bin/xattr -lr "$app" || true
    echo
    echo "=== recursive ls ==="
    /usr/bin/find "$app" -maxdepth 8 -exec /bin/ls -ldeO@ {} + || true
  } > "$out" 2>&1
}

record_quarantine_oracle() {
  local app="$1"
  local out="$2"
  local bundle_qtn="absent"
  local exe_qtn="absent"
  local verdict="inconclusive"

  {
    echo "app=$app"
    if [[ -z "$app" || ! -d "$app" ]]; then
      echo "verdict=inconclusive"
      echo "reason=extracted_app_missing"
      return
    fi

    echo "bundle_quarantine:"
    if /usr/bin/xattr -p com.apple.quarantine "$app" 2>/dev/null; then
      bundle_qtn="present"
    else
      echo "<absent>"
    fi

    echo
    echo "executable_quarantine:"
    if /usr/bin/xattr -p com.apple.quarantine "$app/Contents/MacOS/payload" 2>/dev/null; then
      exe_qtn="present"
    else
      echo "<absent>"
    fi

    if [[ "$bundle_qtn" == "absent" && "$exe_qtn" == "absent" ]]; then
      verdict="candidate_positive_unquarantined_app"
    elif [[ "$bundle_qtn" == "present" || "$exe_qtn" == "present" ]]; then
      verdict="negative_or_patched_quarantine_present"
    fi

    echo
    echo "bundle_qtn=$bundle_qtn"
    echo "executable_qtn=$exe_qtn"
    echo "verdict=$verdict"
  } > "$out" 2>&1
}

write_summary() {
  local app="$1"
  {
    echo "# Packet 009 supplied ZIP probe"
    echo
    echo "run_dir: \`$RUN_DIR\`"
    echo "zip: \`$ZIP\`"
    echo "download_copy: \`$DOWNLOAD_COPY\`"
    echo "selected_app: \`$app\`"
    echo
    echo "## Context"
    echo
    sed -n '1,80p' "$RUN_DIR/run-context.txt"
    echo
    echo "## Oracle"
    echo
    sed -n '1,120p' "$RUN_DIR/quarantine-oracle.txt"
    echo
    echo "## Candidate Apps"
    echo
    sed -n '1,80p' "$RUN_DIR/candidate-apps.tsv"
  } > "$RUN_DIR/run-summary.md"
}

{
  echo "workspace=$WORKSPACE"
  echo "artifacts=$ARTIFACTS"
  echo "run_dir=$RUN_DIR"
  echo "zip=$ZIP"
  echo "download_copy=$DOWNLOAD_COPY"
  echo "build=$(safe_sw_build_slug)"
  echo "wait_mode=$WAIT_MODE"
  echo "wait_seconds=$WAIT_SECONDS"
  echo "set_quarantine=$SET_QUARANTINE"
  echo "quarantine_value=$QVAL"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sw_vers
} > "$RUN_DIR/run-context.txt"

sw_vers > "$RUN_DIR/metadata/sw_vers.txt" 2>&1 || true
spctl --status > "$RUN_DIR/metadata/spctl-status.txt" 2>&1 || true
csrutil status > "$RUN_DIR/metadata/csrutil-status.txt" 2>&1 || true

/bin/cp -p "$ZIP" "$RUN_DIR/input/original.zip"
/usr/bin/shasum -a 256 "$ZIP" > "$RUN_DIR/input/original-sha256.txt"
path_snapshot "$ZIP" "$RUN_DIR/input/original-snapshot.txt"

/bin/cp -p "$ZIP" "$DOWNLOAD_COPY"
if ! /usr/bin/xattr -p com.apple.quarantine "$DOWNLOAD_COPY" > "$RUN_DIR/input/download-copy-quarantine.txt" 2>&1; then
  if [[ "$SET_QUARANTINE" == "1" ]]; then
    /usr/bin/xattr -w com.apple.quarantine "$QVAL" "$DOWNLOAD_COPY"
    /usr/bin/xattr -p com.apple.quarantine "$DOWNLOAD_COPY" > "$RUN_DIR/input/download-copy-quarantine-after-set.txt" 2>&1 || true
  fi
fi
path_snapshot "$DOWNLOAD_COPY" "$RUN_DIR/input/download-copy-snapshot.txt"

record_app_candidate_table "$RUN_DIR/candidate-apps-before.tsv"

echo "[*] run dir: $RUN_DIR"
echo "[*] copied ZIP to: $DOWNLOAD_COPY"
echo "[*] opening supplied ZIP through LaunchServices / Archive Utility"

START_EPOCH="$(date +%s)"
START_LOG="$(date '+%Y-%m-%d %H:%M:%S')"
: > "$RUN_DIR/start.marker"
set +e
/usr/bin/open "$DOWNLOAD_COPY" > "$RUN_DIR/open.stdout.txt" 2> "$RUN_DIR/open.stderr.txt"
OPEN_STATUS=$?
set -e
echo "$OPEN_STATUS" > "$RUN_DIR/open-status.txt"

prompt_or_sleep

END_EPOCH="$(date +%s)"
END_LOG="$(date '+%Y-%m-%d %H:%M:%S')"

{
  echo "start_epoch=$START_EPOCH"
  echo "end_epoch=$END_EPOCH"
  echo "log_start=$START_LOG"
  echo "log_end=$END_LOG"
  echo "open_status=$OPEN_STATUS"
  echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$RUN_DIR/run-context.txt"

record_app_candidate_table "$RUN_DIR/candidate-apps.tsv"
APP="$(select_candidate_app "$RUN_DIR/candidate-apps.tsv" "$START_EPOCH")"
echo "$APP" > "$RUN_DIR/selected-app.txt"

/usr/bin/log show --start "$START_LOG" --end "$END_LOG" --style compact --predicate "$LOG_PREDICATE" > "$RUN_DIR/logs/archiveutility-log.txt" 2>&1 || true

record_recursive_app_state "$APP" "$RUN_DIR/output-xattrs-and-acls.txt"
record_quarantine_oracle "$APP" "$RUN_DIR/quarantine-oracle.txt"

if [[ -n "$APP" && -d "$APP" ]]; then
  spctl --assess --type execute --verbose=4 "$APP" > "$RUN_DIR/spctl.txt" 2>&1 || true
  codesign -dv --verbose=4 "$APP" > "$RUN_DIR/codesign.txt" 2>&1 || true
fi

write_summary "$APP"
write_sha256_manifest "$RUN_DIR" "$RUN_DIR/metadata/sha256-manifest.txt"

echo "[*] complete: $RUN_DIR"
echo "$RUN_DIR"
