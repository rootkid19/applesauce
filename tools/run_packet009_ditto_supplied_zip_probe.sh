#!/bin/zsh
set -euo pipefail
setopt typeset_silent
setopt null_glob

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  local code="${1:-2}"
  cat >&2 <<'EOF'
usage:
  ./tools/run_packet009_ditto_supplied_zip_probe.sh --zip <zip> [options]

Purpose:
  Probe a supplied CVE-2026-28914 ZIP through direct /usr/bin/ditto extraction
  and record whether the extracted app bundle retains com.apple.quarantine.

  This is intentionally separate from the Archive Utility / LaunchServices
  probe. It mirrors the core of an externally supplied ditto-based checker:
  copy ZIP -> synthesize Safari quarantine on the copy -> ditto -x -k ->
  inspect the extracted app and executable quarantine xattrs.

Options:
  --zip <path>                  supplied ZIP to extract
  --out <dir>                   override run directory
  --app-rel <path>              app path inside extraction root
                                (default: CVE28914Drop/CVE28914Payload.app)
  --quarantine-value <value>    quarantine xattr to write to the input copy
  --launch-if-positive          launch the extracted app only if both bundle
                                and executable quarantine xattrs are absent
  -h, --help                    show this help

Environment:
  APPLESAUCE_ARTIFACTS          override artifacts root
  APPLESAUCE_WORKSPACE          override workspace root

Defaults:
  out: <artifacts>/runtime/packet009-zip-gatekeeper/<version>-<build>-<stamp>-ditto-supplied-zip

Run from a normal Terminal while booted into the target OS. By default this
does not launch the extracted app; use --launch-if-positive only after deciding
that executing the marker payload is acceptable.
EOF
  exit "$code"
}

ZIP=""
OUT_OVERRIDE=""
APP_REL="CVE28914Drop/CVE28914Payload.app"
LAUNCH_IF_POSITIVE=0
QVAL=""
MARKER="$HOME/Desktop/cve-2026-28914-payload-marker.txt"

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
    --app-rel)
      [[ $# -ge 2 ]] || usage
      APP_REL="$2"
      shift 2
      ;;
    --quarantine-value)
      [[ $# -ge 2 ]] || usage
      QVAL="$2"
      shift 2
      ;;
    --launch-if-positive)
      LAUNCH_IF_POSITIVE=1
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

require_cmd /usr/bin/ditto
require_cmd /usr/bin/xattr
require_cmd /usr/bin/find
require_cmd /usr/bin/stat
require_cmd /usr/bin/log
require_cmd /usr/bin/shasum
require_cmd /bin/cp
require_cmd /bin/mkdir
require_cmd /bin/ls
require_cmd sw_vers

WORKSPACE="$(workspace_root)"
ARTIFACTS="$(artifact_root)"
STAMP="$(timestamp_utc)"
RUN_PARENT="$ARTIFACTS/runtime/packet009-zip-gatekeeper"
RUN_DIR="${OUT_OVERRIDE:-$RUN_PARENT/$(safe_sw_build_slug)-$STAMP-ditto-supplied-zip}"
INPUT_COPY="$RUN_DIR/input/input.zip"
EXTRACT_DIR="$RUN_DIR/extracted"
APP="$EXTRACT_DIR/$APP_REL"
EXE="$APP/Contents/MacOS/payload"
LOG_PREDICATE='process == "ditto" OR process == "QuarantineService" OR process == "syspolicyd" OR eventMessage CONTAINS[c] "quarantine" OR eventMessage CONTAINS[c] "xattr" OR eventMessage CONTAINS[c] "ACL"'

if [[ -z "$QVAL" ]]; then
  QVAL="0083;$(printf '%x' "$(date +%s)");Safari;https://example.invalid/$(basename "$ZIP")"
fi

mkdir -p "$RUN_DIR"/{input,logs,metadata}
mkdir -p "$EXTRACT_DIR"

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

record_tree() {
  local root="$1"
  local out="$2"
  {
    echo "root=$root"
    if [[ -d "$root" ]]; then
      /usr/bin/find "$root" -maxdepth 10 -exec /bin/ls -ldeO@ {} + || true
    else
      echo "exists=0"
    fi
  } > "$out" 2>&1
}

record_xattrs_recursive() {
  local root="$1"
  local out="$2"
  {
    echo "root=$root"
    if [[ -e "$root" ]]; then
      /usr/bin/xattr -lr "$root" || true
    else
      echo "exists=0"
    fi
  } > "$out" 2>&1
}

q_status() {
  local path="$1"
  if /usr/bin/xattr -p com.apple.quarantine "$path" >/dev/null 2>&1; then
    echo "present"
  else
    echo "absent"
  fi
}

q_value() {
  local path="$1"
  /usr/bin/xattr -p com.apple.quarantine "$path" 2>/dev/null || true
}

write_oracle_and_report() {
  local bundle_qtn="absent"
  local exe_qtn="absent"
  local zip_qtn="absent"
  local verdict="inconclusive"
  local launch_attempted="0"
  local marker_written="0"

  zip_qtn="$(q_status "$INPUT_COPY")"

  {
    echo "app=$APP"
    echo "executable=$EXE"
    if [[ ! -d "$APP" || ! -x "$EXE" ]]; then
      echo "verdict=error_payload_not_found"
      echo "reason=expected_app_or_executable_missing"
    else
      bundle_qtn="$(q_status "$APP")"
      exe_qtn="$(q_status "$EXE")"

      echo "zip_qtn=$zip_qtn"
      echo "bundle_qtn=$bundle_qtn"
      echo "executable_qtn=$exe_qtn"
      echo "bundle_quarantine_value=$(q_value "$APP")"
      echo "executable_quarantine_value=$(q_value "$EXE")"

      if [[ "$bundle_qtn" == "absent" && "$exe_qtn" == "absent" ]]; then
        verdict="candidate_positive_quarantine_missing_ditto"
      elif [[ "$bundle_qtn" == "present" || "$exe_qtn" == "present" ]]; then
        verdict="negative_or_patched_quarantine_present_ditto"
      fi

      if [[ "$verdict" == "candidate_positive_quarantine_missing_ditto" && "$LAUNCH_IF_POSITIVE" == "1" ]]; then
        launch_attempted="1"
        rm -f "$MARKER"
        /usr/bin/open -W -n "$APP" >/dev/null 2>&1 || true
        if [[ -s "$MARKER" ]]; then
          marker_written="1"
        fi
      fi
    fi

    echo "verdict=$verdict"
    echo "launch_attempted=$launch_attempted"
    echo "payload_marker_written=$marker_written"
    echo "marker=$MARKER"
  } > "$RUN_DIR/quarantine-oracle.txt" 2>&1

  {
    echo "work_dir=$RUN_DIR"
    echo "zip=$ZIP"
    echo "host=$(sw_vers -productVersion 2>/dev/null || echo unknown) build=$(sw_vers -buildVersion 2>/dev/null || echo unknown)"
    echo "zip_quarantine=$([[ "$zip_qtn" == "present" ]] && echo 1 || echo 0)"
    if [[ -d "$APP" && -x "$EXE" ]]; then
      bundle_qtn="$(q_status "$APP")"
      exe_qtn="$(q_status "$EXE")"
      echo "bundle_quarantine=$([[ "$bundle_qtn" == "present" ]] && echo 1 || echo 0)"
      echo "executable_quarantine=$([[ "$exe_qtn" == "present" ]] && echo 1 || echo 0)"
      echo "bundle_quarantine_value=$(q_value "$APP")"
      echo "executable_quarantine_value=$(q_value "$EXE")"
    else
      echo "verdict=ERROR_PAYLOAD_NOT_FOUND"
      echo "expected_app=$APP"
    fi
    grep '^verdict=' "$RUN_DIR/quarantine-oracle.txt" || true
    grep '^launch_attempted=' "$RUN_DIR/quarantine-oracle.txt" || true
    grep '^payload_marker_written=' "$RUN_DIR/quarantine-oracle.txt" || true
    echo "report=$RUN_DIR/friend-compatible-report.txt"
    echo "app_path=$APP"
  } > "$RUN_DIR/friend-compatible-report.txt" 2>&1
}

write_summary() {
  {
    echo "# Packet 009 ditto supplied ZIP probe"
    echo
    echo "run_dir: \`$RUN_DIR\`"
    echo "zip: \`$ZIP\`"
    echo "input_copy: \`$INPUT_COPY\`"
    echo "extract_dir: \`$EXTRACT_DIR\`"
    echo "app: \`$APP\`"
    echo
    echo "## Context"
    echo
    sed -n '1,100p' "$RUN_DIR/run-context.txt"
    echo
    echo "## Oracle"
    echo
    sed -n '1,120p' "$RUN_DIR/quarantine-oracle.txt"
    echo
    echo "## Friend-Compatible Report"
    echo
    sed -n '1,120p' "$RUN_DIR/friend-compatible-report.txt"
  } > "$RUN_DIR/run-summary.md"
}

{
  echo "workspace=$WORKSPACE"
  echo "artifacts=$ARTIFACTS"
  echo "run_dir=$RUN_DIR"
  echo "zip=$ZIP"
  echo "input_copy=$INPUT_COPY"
  echo "extract_dir=$EXTRACT_DIR"
  echo "app_rel=$APP_REL"
  echo "app=$APP"
  echo "executable=$EXE"
  echo "build=$(safe_sw_build_slug)"
  echo "launch_if_positive=$LAUNCH_IF_POSITIVE"
  echo "quarantine_value=$QVAL"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sw_vers
} > "$RUN_DIR/run-context.txt"

sw_vers > "$RUN_DIR/metadata/sw_vers.txt" 2>&1 || true
spctl --status > "$RUN_DIR/metadata/spctl-status.txt" 2>&1 || true
csrutil status > "$RUN_DIR/metadata/csrutil-status.txt" 2>&1 || true

/bin/cp "$ZIP" "$INPUT_COPY"
/usr/bin/xattr -w com.apple.quarantine "$QVAL" "$INPUT_COPY"

/usr/bin/shasum -a 256 "$ZIP" > "$RUN_DIR/input/original-sha256.txt"
/usr/bin/shasum -a 256 "$INPUT_COPY" > "$RUN_DIR/input/input-copy-sha256.txt"
path_snapshot "$ZIP" "$RUN_DIR/input/original-snapshot.txt"
path_snapshot "$INPUT_COPY" "$RUN_DIR/input/input-copy-snapshot.txt"

if command -v zipinfo >/dev/null 2>&1; then
  zipinfo -v "$INPUT_COPY" > "$RUN_DIR/input/zipinfo-v.txt" 2>&1 || true
fi

echo "[*] run dir: $RUN_DIR"
echo "[*] extracting supplied ZIP with /usr/bin/ditto"

START_LOG="$(date '+%Y-%m-%d %H:%M:%S')"
set +e
/usr/bin/ditto -x -k "$INPUT_COPY" "$EXTRACT_DIR" > "$RUN_DIR/ditto.stdout.txt" 2> "$RUN_DIR/ditto.stderr.txt"
DITTO_STATUS=$?
set -e
END_LOG="$(date '+%Y-%m-%d %H:%M:%S')"
echo "$DITTO_STATUS" > "$RUN_DIR/ditto-status.txt"

{
  echo "ditto_status=$DITTO_STATUS"
  echo "log_start=$START_LOG"
  echo "log_end=$END_LOG"
  echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$RUN_DIR/run-context.txt"

/usr/bin/log show --start "$START_LOG" --end "$END_LOG" --style compact --predicate "$LOG_PREDICATE" > "$RUN_DIR/logs/ditto-quarantine-log.txt" 2>&1 || true

record_tree "$EXTRACT_DIR" "$RUN_DIR/extracted-tree.txt"
record_xattrs_recursive "$EXTRACT_DIR" "$RUN_DIR/extracted-xattrs.txt"
path_snapshot "$APP" "$RUN_DIR/output-app-snapshot.txt"
path_snapshot "$EXE" "$RUN_DIR/output-executable-snapshot.txt"

write_oracle_and_report

if [[ -d "$APP" ]]; then
  spctl --assess --type execute --verbose=4 "$APP" > "$RUN_DIR/spctl.txt" 2>&1 || true
  codesign -dv --verbose=4 "$APP" > "$RUN_DIR/codesign.txt" 2>&1 || true
fi

write_summary
write_sha256_manifest "$RUN_DIR" "$RUN_DIR/metadata/sha256-manifest.txt"

echo "[*] complete: $RUN_DIR"
echo "$RUN_DIR"
