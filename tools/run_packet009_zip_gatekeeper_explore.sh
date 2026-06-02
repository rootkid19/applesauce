#!/bin/zsh
set -euo pipefail
setopt typeset_silent
setopt null_glob

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  local code="${1:-2}"
  cat >&2 <<'EOF'
usage:
  ./tools/run_packet009_zip_gatekeeper_explore.sh [options]

Purpose:
  Collect bounded Packet 009 exploratory runtime artifacts for CVE-2026-28914.
  This builds controlled ZIP inputs, opens them through normal LaunchServices /
  Archive Utility, and records quarantine xattrs, logs, preferences, and control
  outputs. It does not use direct ArchiveService XPC or custom Apple Events.

Options:
  --out <dir>                   override run directory
  --wait prompt                 wait for Enter after each Archive Utility open
  --wait seconds                sleep after each Archive Utility open
  --wait-seconds <n>            seconds for --wait seconds (default: 20)
  --skip-recursive-off          skip the recursive-disabled control
  --skip-follow-inner           skip second-hop opens of extracted inner ZIPs
  --prepare-only                build inputs and metadata without opening ZIPs
  --no-restore-preferences      leave Archive Utility recursive preference as set
  -h, --help                    show this help

Defaults:
  out: artifacts/runtime/packet009-zip-gatekeeper/<version>-<build>-<stamp>-nested-explore
  wait: prompt

Run from a normal Terminal while booted into the target OS. GUI open behavior
from nested agent shells may be unreliable. The script pins Archive Utility to
extract into the same folder as the archive for comparable case snapshots, then
restores the prior Archive Utility preference domain on exit.
EOF
  exit "$code"
}

WAIT_MODE="prompt"
WAIT_SECONDS=20
SKIP_RECURSIVE_OFF=0
SKIP_FOLLOW_INNER=0
RESTORE_PREFERENCES=1
OUT_OVERRIDE=""
PREPARE_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --skip-recursive-off)
      SKIP_RECURSIVE_OFF=1
      shift
      ;;
    --skip-follow-inner)
      SKIP_FOLLOW_INNER=1
      shift
      ;;
    --prepare-only)
      PREPARE_ONLY=1
      shift
      ;;
    --no-restore-preferences)
      RESTORE_PREFERENCES=0
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

case "$WAIT_MODE" in
  prompt|seconds)
    ;;
  *)
    echo "unsupported --wait mode: $WAIT_MODE" >&2
    usage
    ;;
esac

if ! [[ "$WAIT_SECONDS" == <-> ]]; then
  echo "--wait-seconds must be an integer" >&2
  exit 2
fi

WORKSPACE="$(workspace_root)"
ARTIFACTS="$(artifact_root)"
STAMP="$(timestamp_utc)"
RUN_PARENT="$ARTIFACTS/runtime/packet009-zip-gatekeeper"
RUN_DIR="${OUT_OVERRIDE:-$RUN_PARENT/$(safe_sw_build_slug)-$STAMP-nested-explore}"
LOG_PREDICATE='process == "Archive Utility" OR process == "ArchiveService" OR eventMessage CONTAINS[c] "quarantine" OR eventMessage CONTAINS[c] "DSQuarantine" OR eventMessage CONTAINS[c] "ArchiveService"'
QVAL="0081;$(printf '%x' "$(date +%s)");Safari;Packet009"
LOG_PID=""
PREF_EXISTED=0
PREF_VALUE=""
PREF_DOMAIN_EXISTED=0
PREF_EXPORT=""

require_cmd /usr/bin/ditto
require_cmd /usr/bin/open
require_cmd /usr/bin/xattr
require_cmd /usr/bin/defaults
require_cmd /usr/bin/log
require_cmd /usr/bin/find
require_cmd /usr/bin/stat
require_cmd /bin/chmod
require_cmd /bin/mkdir
require_cmd /bin/cp
require_cmd sw_vers

mkdir -p "$RUN_DIR"/{inputs,work,logs,snapshots,metadata}

write_host_state() {
  local out="$1"
  mkdir -p "$out"
  sw_vers > "$out/sw_vers.txt" 2>&1 || true
  system_profiler SPSoftwareDataType > "$out/system_profiler-SPSoftwareDataType.txt" 2>&1 || true
  spctl --status > "$out/spctl-status.txt" 2>&1 || true
  csrutil status > "$out/csrutil-status.txt" 2>&1 || true
}

read_recursive_pref() {
  local out="$1"
  if /usr/bin/defaults read com.apple.archiveutility dearchive-recursively > "$out" 2>&1; then
    return 0
  fi
  return 1
}

set_recursive_pref() {
  local value="$1"
  /usr/bin/defaults write com.apple.archiveutility dearchive-recursively -bool "$value"
}

restore_recursive_pref() {
  [[ "$RESTORE_PREFERENCES" == "1" ]] || return 0

  if [[ -n "$PREF_EXPORT" ]]; then
    if [[ "$PREF_DOMAIN_EXISTED" == "1" && -s "$PREF_EXPORT" ]]; then
      /usr/bin/defaults delete com.apple.archiveutility >/dev/null 2>&1 || true
      /usr/bin/defaults import com.apple.archiveutility "$PREF_EXPORT" >/dev/null 2>&1 || true
    else
      /usr/bin/defaults delete com.apple.archiveutility >/dev/null 2>&1 || true
    fi
    return 0
  fi

  if [[ "$PREF_EXISTED" == "1" ]]; then
    case "$PREF_VALUE" in
      1|true|TRUE|True|YES|yes)
        /usr/bin/defaults write com.apple.archiveutility dearchive-recursively -bool true >/dev/null 2>&1 || true
        ;;
      *)
        /usr/bin/defaults write com.apple.archiveutility dearchive-recursively -bool false >/dev/null 2>&1 || true
        ;;
    esac
  else
    /usr/bin/defaults delete com.apple.archiveutility dearchive-recursively >/dev/null 2>&1 || true
  fi
}

snapshot_archiveutility_preferences() {
  local out_dir="$1"
  mkdir -p "$out_dir"
  PREF_EXPORT="$out_dir/archiveutility-before.plist"

  if /usr/bin/defaults export com.apple.archiveutility "$PREF_EXPORT" >/dev/null 2>&1; then
    PREF_DOMAIN_EXISTED=1
  else
    PREF_DOMAIN_EXISTED=0
    : > "$PREF_EXPORT"
  fi

  /usr/bin/defaults read com.apple.archiveutility > "$out_dir/archiveutility-before.txt" 2>&1 || true
}

pin_archiveutility_case_preferences() {
  /usr/bin/defaults write com.apple.archiveutility dearchive-into -string "."
  /usr/bin/defaults write com.apple.archiveutility dearchive-into-location -dict Selection UseSameFolder
  /usr/bin/defaults write com.apple.archiveutility dearchive-move-after -string "."
  /usr/bin/defaults write com.apple.archiveutility dearchive-move-after-location -dict Selection UseSameFolder
  /usr/bin/defaults write com.apple.archiveutility dearchive-move-intermediate-after -string "/dev/null"
  /usr/bin/defaults write com.apple.archiveutility dearchive-move-intermediate-after-location -dict Selection Delete
  /usr/bin/defaults write com.apple.archiveutility dearchive-recursively -bool true
  /usr/bin/defaults read com.apple.archiveutility > "$RUN_DIR/snapshots/archiveutility-pinned.txt" 2>&1 || true
}

stop_log_stream() {
  if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
    kill "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  stop_log_stream
  restore_recursive_pref
}

trap cleanup EXIT

prompt_or_sleep() {
  local message="$1"
  if [[ "$WAIT_MODE" == "seconds" ]]; then
    echo "[*] $message; sleeping ${WAIT_SECONDS}s"
    sleep "$WAIT_SECONDS"
    return
  fi

  printf '%s\n' "[*] $message"
  printf '%s' "    Press Enter after Archive Utility finishes this case: "
  local reply
  IFS= read -r reply
}

copy_case_input() {
  local source="$1"
  local target="$2"
  local quarantine="$3"

  /bin/cp -p "$source" "$target"
  if [[ "$quarantine" == "1" ]]; then
    /usr/bin/xattr -w com.apple.quarantine "$QVAL" "$target"
  else
    /usr/bin/xattr -d com.apple.quarantine "$target" >/dev/null 2>&1 || true
  fi
}

capture_path_snapshot() {
  local path="$1"
  local out="$2"
  {
    echo "path=$path"
    if [[ -e "$path" ]]; then
      /bin/ls -laeO@ "$path" || true
      /usr/bin/stat -f 'dev=%d ino=%i mode=%p uid=%u gid=%g size=%z mtime=%m birthtime=%B type=%HT' "$path" || true
      /usr/bin/xattr -l "$path" || true
    else
      echo "exists=0"
    fi
  } > "$out" 2>&1
}

capture_spctl_for_apps() {
  local case_dir="$1"
  local out="$2"
  : > "$out"
  if ! command -v /usr/sbin/spctl >/dev/null 2>&1; then
    echo "spctl unavailable" >> "$out"
    return
  fi

  /usr/bin/find "$case_dir" -maxdepth 10 -name '*.app' -print0 2>/dev/null | while IFS= read -r -d '' app; do
    local assess_status
    {
      echo "=== $app ==="
    } >> "$out" 2>&1 || true
    set +e
    /usr/sbin/spctl --assess --type execute --verbose=4 "$app" >> "$out" 2>&1
    assess_status=$?
    set -e
    {
      echo "status=$assess_status"
    } >> "$out" 2>&1 || true
  done
}

capture_case() {
  local case_dir="$1"
  local case_start_epoch="$2"
  local case_end_epoch
  local log_start
  local log_end
  local start_marker="$case_dir/case-start.marker"
  case_end_epoch="$(date +%s)"
  log_start="$(date -r "$case_start_epoch" '+%Y-%m-%d %H:%M:%S')"
  log_end="$(date -r "$case_end_epoch" '+%Y-%m-%d %H:%M:%S')"

  /usr/bin/find "$case_dir" -maxdepth 10 -print > "$case_dir/tree.txt" 2>&1 || true
  /usr/bin/xattr -lr "$case_dir" > "$case_dir/xattrs-recursive.txt" 2>&1 || true
  capture_spctl_for_apps "$case_dir" "$case_dir/spctl-apps.txt"
  /usr/bin/log show --start "$log_start" --end "$log_end" --style compact --predicate "$LOG_PREDICATE" > "$case_dir/log-show.txt" 2>&1 || true
  capture_archive_targets "$case_dir"
  capture_fallback_outputs "$case_dir" "$start_marker"
  {
    echo "case_start_epoch=$case_start_epoch"
    echo "case_end_epoch=$case_end_epoch"
    echo "case_end_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "log_start=$log_start"
    echo "log_end=$log_end"
  } >> "$case_dir/case-context.txt"
}

capture_archive_targets() {
  local case_dir="$1"
  local out="$case_dir/archive-targets.txt"
  : > "$out"

  if [[ ! -f "$case_dir/log-show.txt" ]]; then
    echo "log_show=absent" >> "$out"
    return 0
  fi

  {
    echo "# ArchiveService file-issue-extension targets observed in this case log"
    /usr/bin/sed -n 's/.*file-issue-extension target:\(.*\) extension-class:.*/target=\1/p' "$case_dir/log-show.txt" | /usr/bin/sort -u
  } >> "$out" 2>&1 || true
}

capture_fallback_outputs() {
  local case_dir="$1"
  local start_marker="$2"
  local out="$case_dir/fallback-output-candidates.txt"
  local roots=("$HOME/Downloads" "$HOME/Desktop")
  local root
  local candidate_count=0
  : > "$out"

  {
    echo "# Diagnostic only: candidates outside the case dir do not make the case valid."
    for root in "${roots[@]}"; do
      echo "## root=$root"
      if [[ ! -d "$root" ]]; then
        echo "missing=1"
        continue
      fi

      while IFS= read -r candidate; do
        candidate_count=$((candidate_count + 1))
        echo "candidate=$candidate"
        /bin/ls -ldeO@ "$candidate" 2>&1 || true
        /usr/bin/stat -f 'dev=%d ino=%i mode=%p uid=%u gid=%g size=%z mtime=%m birthtime=%B type=%HT' "$candidate" 2>&1 || true
        /usr/bin/xattr -l "$candidate" 2>&1 || true
        echo
      done < <(/usr/bin/find "$root" -maxdepth 3 \( -name 'Payload*.app' -o -name 'inner-payload*.zip' -o -name 'nested*' \) -newer "$start_marker" -print 2>/dev/null)
    done
    echo "candidate_count=$candidate_count"
  } >> "$out" 2>&1 || true
}

write_extraction_status() {
  local name="$1"
  local case_dir="$2"
  local expected="$3"
  local archive="${4:-}"
  local missing_source="${5:-}"
  local open_status="absent"
  local case_status="malformed"
  local reason="unknown"
  local payload_matches=("$case_dir"/**/Payload.app(N/))
  local inner_matches=("$case_dir"/**/inner-payload.zip(N.))
  local payload="${payload_matches[1]:-}"
  local inner="${inner_matches[1]:-}"

  if [[ -f "$case_dir/open-status.txt" ]]; then
    open_status="$(sed -n '1p' "$case_dir/open-status.txt")"
  fi

  case "$expected" in
    payload-app)
      if [[ -n "$payload" ]]; then
        case_status="ok"
        reason="payload_app_found"
      else
        case_status="malformed"
        reason="expected_payload_app_missing"
      fi
      ;;
    inner-or-payload)
      if [[ -n "$payload" ]]; then
        case_status="ok"
        reason="payload_app_found"
      elif [[ -n "$inner" ]]; then
        case_status="ok"
        reason="inner_zip_found"
      else
        case_status="malformed"
        reason="expected_inner_zip_or_payload_app_missing"
      fi
      ;;
    skipped)
      case_status="skipped"
      reason="missing_source_archive"
      ;;
    *)
      case_status="malformed"
      reason="unsupported_expected_output"
      ;;
  esac

  {
    echo "case=$name"
    echo "status=$case_status"
    echo "reason=$reason"
    echo "expected=$expected"
    echo "archive=$archive"
    echo "open_status=$open_status"
    echo "payload_app=$payload"
    echo "inner_payload_zip=$inner"
    echo "missing_source=$missing_source"
    echo "archive_targets_file=$case_dir/archive-targets.txt"
    echo "fallback_outputs_file=$case_dir/fallback-output-candidates.txt"
  } > "$case_dir/extraction-status.txt"

  if [[ "$case_status" == "malformed" ]]; then
    echo "[!] $name extraction status: malformed ($reason); see $case_dir/extraction-status.txt" >&2
  fi
}

write_run_validity() {
  local validity="$RUN_DIR/run-validity.txt"
  local status_files=("$RUN_DIR"/case-*/extraction-status.txt(N))
  local ok=0
  local malformed=0
  local skipped=0
  local f

  for f in "${status_files[@]}"; do
    if /usr/bin/grep -q '^status=ok$' "$f" 2>/dev/null; then
      ok=$((ok + 1))
    elif /usr/bin/grep -q '^status=malformed$' "$f" 2>/dev/null; then
      malformed=$((malformed + 1))
    elif /usr/bin/grep -q '^status=skipped$' "$f" 2>/dev/null; then
      skipped=$((skipped + 1))
    fi
  done

  {
    if [[ "$malformed" -gt 0 ]]; then
      echo "run_validity=invalid"
    elif [[ "$ok" -gt 0 ]]; then
      echo "run_validity=interpretable"
    else
      echo "run_validity=no_runtime_cases"
    fi
    echo "ok_cases=$ok"
    echo "malformed_cases=$malformed"
    echo "skipped_cases=$skipped"
    echo "status_files=${#status_files[@]}"
  } > "$validity"
}

run_case() {
  local name="$1"
  local source="$2"
  local archive_name="$3"
  local quarantine="$4"
  local recursive_pref="$5"
  local wait_message="$6"
  local case_dir="$RUN_DIR/$name"
  local archive="$case_dir/$archive_name"
  local open_status
  local case_start

  mkdir -p "$case_dir"
  set_recursive_pref "$recursive_pref"
  read_recursive_pref "$case_dir/dearchive-recursively.txt" || true
  copy_case_input "$source" "$archive" "$quarantine"
  capture_path_snapshot "$archive" "$case_dir/input-archive-snapshot.txt"

  {
    echo "case=$name"
    echo "archive=$archive"
    echo "quarantine_input=$quarantine"
    echo "recursive_pref=$recursive_pref"
    echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$case_dir/case-context.txt"

  echo "[*] opening $name: $archive"
  case_start="$(date +%s)"
  : > "$case_dir/case-start.marker"
  set +e
  /usr/bin/open "$archive" > "$case_dir/open.stdout.txt" 2> "$case_dir/open.stderr.txt"
  open_status=$?
  set -e
  echo "$open_status" > "$case_dir/open-status.txt"

  prompt_or_sleep "$wait_message"
  capture_case "$case_dir" "$case_start"
  case "$name" in
    case-direct-quarantined)
      write_extraction_status "$name" "$case_dir" "payload-app" "$archive"
      ;;
    case-nested-*)
      write_extraction_status "$name" "$case_dir" "inner-or-payload" "$archive"
      ;;
    *)
      write_extraction_status "$name" "$case_dir" "inner-or-payload" "$archive"
      ;;
  esac
}

run_existing_archive_case() {
  local name="$1"
  local source_archive="$2"
  local archive_name="$3"
  local recursive_pref="$4"
  local wait_message="$5"
  local case_dir="$RUN_DIR/$name"
  local archive="$case_dir/$archive_name"
  local open_status
  local case_start

  mkdir -p "$case_dir"

  if [[ ! -f "$source_archive" ]]; then
    {
      echo "case=$name"
      echo "skipped=1"
      echo "missing_source=$source_archive"
      echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$case_dir/case-context.txt"
    write_extraction_status "$name" "$case_dir" "skipped" "$archive" "$source_archive"
    echo "[*] skipping $name: missing $source_archive"
    return 0
  fi

  set_recursive_pref "$recursive_pref"
  read_recursive_pref "$case_dir/dearchive-recursively.txt" || true
  /bin/cp -p "$source_archive" "$archive"
  capture_path_snapshot "$source_archive" "$case_dir/source-archive-snapshot.txt"
  capture_path_snapshot "$archive" "$case_dir/input-archive-snapshot.txt"

  {
    echo "case=$name"
    echo "source_archive=$source_archive"
    echo "archive=$archive"
    echo "recursive_pref=$recursive_pref"
    echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$case_dir/case-context.txt"

  echo "[*] opening $name: $archive"
  case_start="$(date +%s)"
  : > "$case_dir/case-start.marker"
  set +e
  /usr/bin/open "$archive" > "$case_dir/open.stdout.txt" 2> "$case_dir/open.stderr.txt"
  open_status=$?
  set -e
  echo "$open_status" > "$case_dir/open-status.txt"

  prompt_or_sleep "$wait_message"
  capture_case "$case_dir" "$case_start"
  write_extraction_status "$name" "$case_dir" "payload-app" "$archive"
}

write_summary() {
  local summary="$RUN_DIR/run-summary.md"
  {
    echo "# Packet 009 exploratory runtime summary"
    echo
    cat "$RUN_DIR/run-context.txt"
    echo
    echo "## Input quarantine value"
    echo
    echo "\`$QVAL\`"
    echo
    echo "## Archive Utility recursive setting"
    echo
    for f in "$RUN_DIR"/snapshots/dearchive-recursively-*.txt; do
      [[ -f "$f" ]] || continue
      echo "### ${f#$RUN_DIR/}"
      sed -n '1,40p' "$f"
      echo
    done
    if [[ -f "$RUN_DIR/run-validity.txt" ]]; then
      echo "## Extraction validity"
      echo
      cat "$RUN_DIR/run-validity.txt"
      echo
      for f in "$RUN_DIR"/case-*/extraction-status.txt; do
        [[ -f "$f" ]] || continue
        echo "### ${f#$RUN_DIR/}"
        sed -n '1,80p' "$f"
        echo
        local target_file="${f:h}/archive-targets.txt"
        if [[ -f "$target_file" ]]; then
          echo "#### ${target_file#$RUN_DIR/}"
          sed -n '1,80p' "$target_file"
          echo
        fi
        local fallback_file="${f:h}/fallback-output-candidates.txt"
        if [[ -f "$fallback_file" ]]; then
          echo "#### ${fallback_file#$RUN_DIR/}"
          sed -n '1,120p' "$fallback_file"
          echo
        fi
      done
    fi
    echo "## Case xattr excerpts"
    echo
    for f in "$RUN_DIR"/case-*/xattrs-recursive.txt; do
      [[ -f "$f" ]] || continue
      echo "### ${f#$RUN_DIR/}"
      if command -v rg >/dev/null 2>&1; then
        rg -n "com.apple.quarantine|Payload.app|inner-payload|nested-payload|direct-payload" "$f" || true
      else
        /usr/bin/grep -En "com.apple.quarantine|Payload.app|inner-payload|nested-payload|direct-payload" "$f" || true
      fi
      echo
    done
    echo "## spctl excerpts"
    echo
    for f in "$RUN_DIR"/case-*/spctl-apps.txt; do
      [[ -f "$f" ]] || continue
      echo "### ${f#$RUN_DIR/}"
      sed -n '1,80p' "$f"
      echo
    done
  } > "$summary"
}

write_handoff() {
  cat > "$RUN_DIR/claude-handoff.md" <<EOF
# Packet 009 Claude Handoff

Run directory:

\`\`\`text
$RUN_DIR
\`\`\`

Compare this run with the paired run from the other Tahoe build. Answer only:

1. Did extraction occur through normal LaunchServices / Archive Utility?
2. Did the nested/recursive case materialize and process \`inner-payload.zip\`?
3. Did the intermediate inner ZIP retain, lose, or never acquire \`com.apple.quarantine\`?
4. Did the final \`Payload.app\` differ between 26.4 and 26.5?
5. Do the direct and unquarantined controls rule out generic Archive Utility/xattr noise?
6. Is validation earned, or should Packet 009 park as root-cause-confirmed with no proven local trigger?

Claim boundary: this is exploratory runtime only. Do not claim a Gatekeeper
bypass without a same-input 26.4/26.5 split, a realistic delivery path, and
negative controls.
EOF
}

write_host_state "$RUN_DIR/metadata/host-state"
snapshot_archiveutility_preferences "$RUN_DIR/snapshots"

if read_recursive_pref "$RUN_DIR/snapshots/dearchive-recursively-before.txt"; then
  PREF_EXISTED=1
  PREF_VALUE="$(sed -n '1p' "$RUN_DIR/snapshots/dearchive-recursively-before.txt")"
else
  PREF_EXISTED=0
  PREF_VALUE=""
fi

pin_archiveutility_case_preferences

{
  echo "workspace=$WORKSPACE"
  echo "artifacts=$ARTIFACTS"
  echo "run_dir=$RUN_DIR"
  echo "build=$(safe_sw_build_slug)"
  echo "wait_mode=$WAIT_MODE"
  echo "wait_seconds=$WAIT_SECONDS"
  echo "skip_recursive_off=$SKIP_RECURSIVE_OFF"
  echo "skip_follow_inner=$SKIP_FOLLOW_INNER"
  echo "prepare_only=$PREPARE_ONLY"
  echo "restore_preferences=$RESTORE_PREFERENCES"
  echo "quarantine_value=$QVAL"
  echo "archive_create_options=ditto --norsrc --noextattr --noqtn --noacl -c -k --keepParent"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sw_vers
} > "$RUN_DIR/run-context.txt"

echo "[*] run dir: $RUN_DIR"
echo "[*] build: $(safe_sw_build_slug)"
echo "[*] wait mode: $WAIT_MODE"

PAYLOAD="$RUN_DIR/work/Payload.app"
mkdir -p "$PAYLOAD/Contents/MacOS"
cat > "$PAYLOAD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>payload</string>
  <key>CFBundleIdentifier</key><string>com.packet009.payload</string>
  <key>CFBundleName</key><string>Payload</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
cat > "$PAYLOAD/Contents/MacOS/payload" <<'SH'
#!/bin/sh
/usr/bin/osascript -e 'display dialog "Packet009 payload opened" buttons {"OK"} default button 1'
SH
/bin/chmod +x "$PAYLOAD/Contents/MacOS/payload"
/usr/bin/xattr -dr com.apple.quarantine "$PAYLOAD" >/dev/null 2>&1 || true

(
  cd "$RUN_DIR/work"
  /usr/bin/ditto --norsrc --noextattr --noqtn --noacl -c -k --keepParent Payload.app "$RUN_DIR/inputs/direct-payload.zip"
  /usr/bin/ditto --norsrc --noextattr --noqtn --noacl -c -k --keepParent Payload.app "$RUN_DIR/inputs/inner-payload.zip"
  /usr/bin/xattr -d com.apple.quarantine "$RUN_DIR/inputs/inner-payload.zip" >/dev/null 2>&1 || true
  /bin/mkdir -p nested
  /bin/cp -p "$RUN_DIR/inputs/inner-payload.zip" nested/inner-payload.zip
  /usr/bin/xattr -d com.apple.quarantine nested/inner-payload.zip >/dev/null 2>&1 || true
  /usr/bin/ditto --norsrc --noextattr --noqtn --noacl -c -k --keepParent nested "$RUN_DIR/inputs/nested-payload.zip"
  /bin/cp -p "$RUN_DIR/inputs/nested-payload.zip" "$RUN_DIR/inputs/nested-payload-unquarantined.zip"
)

/usr/bin/xattr -w com.apple.quarantine "$QVAL" "$RUN_DIR/inputs/direct-payload.zip"
/usr/bin/xattr -w com.apple.quarantine "$QVAL" "$RUN_DIR/inputs/nested-payload.zip"
/usr/bin/xattr -d com.apple.quarantine "$RUN_DIR/inputs/inner-payload.zip" >/dev/null 2>&1 || true
/usr/bin/xattr -d com.apple.quarantine "$RUN_DIR/inputs/nested-payload-unquarantined.zip" >/dev/null 2>&1 || true

{
  for input in "$RUN_DIR"/inputs/*.zip; do
    echo "=== $input ==="
    /bin/ls -laeO@ "$input" || true
    /usr/bin/stat -f 'dev=%d ino=%i mode=%p uid=%u gid=%g size=%z mtime=%m birthtime=%B type=%HT' "$input" || true
    /usr/bin/xattr -l "$input" || true
    echo
  done
} > "$RUN_DIR/snapshots/input-xattrs-before.txt" 2>&1

if [[ "$PREPARE_ONLY" == "1" ]]; then
  write_summary
  write_handoff
  write_sha256_manifest "$RUN_DIR" "$RUN_DIR/metadata/sha256-manifest.txt"
  {
    echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "prepare_only=1"
    echo "run_dir=$RUN_DIR"
  } >> "$RUN_DIR/run-context.txt"
  echo "[*] prepare-only complete: $RUN_DIR"
  echo "$RUN_DIR"
  exit 0
fi

/usr/bin/log stream --style compact --predicate "$LOG_PREDICATE" > "$RUN_DIR/logs/log-stream-archive.txt" 2>&1 &
LOG_PID=$!
echo "$LOG_PID" > "$RUN_DIR/logs/log-stream.pid"
sleep 1

set_recursive_pref true
read_recursive_pref "$RUN_DIR/snapshots/dearchive-recursively-primary.txt" || true

run_case \
  "case-direct-quarantined" \
  "$RUN_DIR/inputs/direct-payload.zip" \
  "direct-payload.zip" \
  "1" \
  "true" \
  "Wait for Archive Utility to finish direct payload extraction"

run_case \
  "case-nested-quarantined-recursive" \
  "$RUN_DIR/inputs/nested-payload.zip" \
  "nested-payload.zip" \
  "1" \
  "true" \
  "Wait for Archive Utility recursive nested extraction to finish"

if [[ "$SKIP_FOLLOW_INNER" != "1" ]]; then
  run_existing_archive_case \
    "case-nested-quarantined-follow-inner" \
    "$RUN_DIR/case-nested-quarantined-recursive/nested/inner-payload.zip" \
    "inner-payload.zip" \
    "true" \
    "Wait for Archive Utility second-hop inner ZIP extraction to finish"
fi

if [[ "$SKIP_RECURSIVE_OFF" != "1" ]]; then
  run_case \
    "case-nested-quarantined-recursive-off" \
    "$RUN_DIR/inputs/nested-payload.zip" \
    "nested-payload.zip" \
    "1" \
    "false" \
    "Wait for Archive Utility non-recursive nested extraction to finish"
fi

run_case \
  "case-nested-unquarantined" \
  "$RUN_DIR/inputs/nested-payload-unquarantined.zip" \
  "nested-payload-unquarantined.zip" \
  "0" \
  "true" \
  "Wait for Archive Utility unquarantined-control extraction to finish"

if [[ "$SKIP_FOLLOW_INNER" != "1" ]]; then
  run_existing_archive_case \
    "case-nested-unquarantined-follow-inner" \
    "$RUN_DIR/case-nested-unquarantined/nested/inner-payload.zip" \
    "inner-payload.zip" \
    "true" \
    "Wait for Archive Utility second-hop unquarantined inner ZIP extraction to finish"
fi

read_recursive_pref "$RUN_DIR/snapshots/dearchive-recursively-after-matrix.txt" || true
write_run_validity
write_summary
write_handoff
write_sha256_manifest "$RUN_DIR" "$RUN_DIR/metadata/sha256-manifest.txt"

{
  echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "run_dir=$RUN_DIR"
} >> "$RUN_DIR/run-context.txt"

echo "[*] complete: $RUN_DIR"
echo "$RUN_DIR"
