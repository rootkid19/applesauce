#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  ./tools/run_packet004_import_move_gate.sh [copy|move|coord-copy|coord-move|all|finder-copy|finder-move|finder-all] [target-dir]

Purpose:
  Exercise normal import/move workflows into a FileProvider domain and capture
  logs for FPDMoveWriterToProvider, FPSandboxingURLWrapper, and sandbox-extension
  helper reachability.

Defaults:
  mode       all
  target-dir ~/Library/Mobile Documents/com~apple~CloudDocs/Packet004ImportMoveGate

Notes:
  all        runs copy, coord-copy, move, coord-move with NSFileManager/NSFileCoordinator.
  finder-*   uses Finder through osascript and may trigger an Automation prompt.
  This is a reachability gate only. Do not race until a run proves the real
  import/move writer and wrapper/helper path were reached.
EOF
}

MODE="${1:-all}"
TARGET_DIR="${2:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Packet004ImportMoveGate}"

case "$MODE" in
  copy|move|coord-copy|coord-move|all|finder-copy|finder-move|finder-all)
    ;;
  *)
    usage
    exit 2
    ;;
esac

packet004_import_move_harness_root() {
  if [[ -n "${PACKET004_IMPORT_MOVE_HARNESS_ROOT:-}" ]]; then
    if [[ -x "$PACKET004_IMPORT_MOVE_HARNESS_ROOT/scripts/build.sh" ]]; then
      cd "$PACKET004_IMPORT_MOVE_HARNESS_ROOT" && pwd
      return
    fi
    echo "PACKET004_IMPORT_MOVE_HARNESS_ROOT is set but missing scripts/build.sh: $PACKET004_IMPORT_MOVE_HARNESS_ROOT" >&2
    exit 2
  fi

  local root
  root="$(applesauce_root)/harnesses/packet004-import-move"
  if [[ -x "$root/scripts/build.sh" ]]; then
    cd "$root" && pwd
    return
  fi

  root="$(workspace_root)/harnesses/packet004-import-move"
  if [[ -x "$root/scripts/build.sh" ]]; then
    cd "$root" && pwd
    return
  fi

  cat >&2 <<'EOF'
Missing Packet 004 import/move harness.

Expected one of:
  <applesauce>/harnesses/packet004-import-move
  <workspace>/harnesses/packet004-import-move

The directory must contain scripts/build.sh.
EOF
  exit 2
}

mode_list() {
  case "$MODE" in
    all)
      print -r -- "copy coord-copy move coord-move"
      ;;
    finder-all)
      print -r -- "finder-copy finder-move"
      ;;
    *)
      print -r -- "$MODE"
      ;;
  esac
}

write_file_snapshot() {
  local label="$1"
  local path="$2"
  local out="$3"
  {
    echo "label=$label"
    echo "path=$path"
    if [[ -e "$path" ]]; then
      echo "exists=1"
      /bin/ls -laeO@ "$path" || true
      /usr/bin/stat -f 'dev=%d ino=%i mode=%p size=%z mtime=%m birthtime=%B type=%HT' "$path" || true
      /usr/bin/xattr -lr "$path" || true
      if command -v mdls >/dev/null 2>&1; then
        /usr/bin/mdls "$path" || true
      fi
    else
      echo "exists=0"
    fi
  } > "$out" 2>&1
}

prepare_source() {
  local op="$1"
  local source="$RUN_DIR/input/packet004-${STAMP}-${op}.txt"
  mkdir -p "$RUN_DIR/input"
  {
    echo "packet004 import/move gate"
    echo "operation=$op"
    echo "stamp=$STAMP"
    echo "source=$source"
    echo "target_dir=$TARGET_DIR"
    echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$source"
  print -r -- "$source"
}

run_one_operation() {
  local op="$1"
  local op_dir="$RUN_DIR/operations/$op"
  local source target op_status

  mkdir -p "$op_dir"
  source="$(prepare_source "$op")"
  target="$TARGET_DIR/$(basename "$source")"

  /bin/rm -f "$target"

  {
    echo "operation=$op"
    echo "source=$source"
    echo "target=$target"
    echo "target_dir=$TARGET_DIR"
    echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$op_dir/operation-summary.txt"

  write_file_snapshot "source.before" "$source" "$op_dir/source.before.txt"
  write_file_snapshot "target.before" "$target" "$op_dir/target.before.txt"

  set +e
  case "$op" in
    copy|move|coord-copy|coord-move)
      "$HARNESS/scripts/run_probe.sh" "$op" "$source" "$target" > "$op_dir/probe.stdout.txt" 2> "$op_dir/probe.stderr.txt"
      op_status=$?
      ;;
    finder-copy|finder-move)
      require_cmd /usr/bin/osascript
      /usr/bin/osascript "$HARNESS/scripts/finder_operation.applescript" "$op" "$source" "$TARGET_DIR" > "$op_dir/probe.stdout.txt" 2> "$op_dir/probe.stderr.txt"
      op_status=$?
      ;;
    *)
      echo "unsupported operation: $op" > "$op_dir/probe.stderr.txt"
      op_status=2
      ;;
  esac
  set -e

  write_file_snapshot "source.after" "$source" "$op_dir/source.after.txt"
  write_file_snapshot "target.after" "$target" "$op_dir/target.after.txt"

  {
    echo "status=$op_status"
    echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >> "$op_dir/operation-summary.txt"

  return 0
}

WORKSPACE="$(workspace_root)"
ARTIFACTS="$(artifact_root)"
HARNESS="$(packet004_import_move_harness_root)"
STAMP="$(timestamp_utc)"
RUN_PARENT="$ARTIFACTS/runtime/packet004-import-move"
RUN_DIR="${RUN_DIR:-$RUN_PARENT/$(safe_sw_build_slug)-$STAMP-$MODE}"
PREDICATE='process == "fileproviderd" OR process == "fileproviderctl" OR process == "Finder" OR process == "bird" OR process == "cloudd" OR eventMessage CONTAINS[c] "FPDMoveWriterToProvider" OR eventMessage CONTAINS[c] "_importURL" OR eventMessage CONTAINS[c] "FPSandboxingURLWrapper" OR eventMessage CONTAINS[c] "wrapperWithURL" OR eventMessage CONTAINS[c] "fp_issueSandboxExtension" OR eventMessage CONTAINS[c] "sandbox extension" OR eventMessage CONTAINS[c] "realpath" OR eventMessage CONTAINS[c] "createItem" OR eventMessage CONTAINS[c] "modifyItem" OR eventMessage CONTAINS[c] "packet004"'
TARGET_HIT_PATTERN='FPDMoveWriterToProvider|_importURL|FPSandboxingURLWrapper|wrapperWithURL|fp_issueSandboxExtension|sandbox_extension_issue_file'
SIBLING_HIT_PATTERN='consumeSandboxFileSystemHash|attaching sandbox extension|scoped|FileURL|modifyItem|createItem|CloudDocs.iCloudDriveFileProvider|BRCFSImporter|FileProvider:default|action finished|sandbox extension'

require_cmd clang
require_cmd /usr/bin/log
require_cmd sw_vers
require_cmd /bin/rm

mkdir -p "$RUN_DIR/environment" "$RUN_DIR/operations"
mkdir -p "$TARGET_DIR"

echo "[*] workspace: $WORKSPACE"
echo "[*] harness: $HARNESS"
echo "[*] run dir: $RUN_DIR"
echo "[*] mode: $MODE"
echo "[*] target dir: $TARGET_DIR"

"$(applesauce_root)/tools/collect_campaign1_host_state.sh" "$RUN_DIR/environment/host-state" >/dev/null

"$HARNESS/scripts/build.sh" > "$RUN_DIR/build.txt" 2>&1

{
  echo "mode=$MODE"
  echo "operations=$(mode_list)"
  echo "target_dir=$TARGET_DIR"
  echo "predicate=$PREDICATE"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "ProductVersion=$(sw_vers -productVersion 2>/dev/null || true)"
  echo "BuildVersion=$(sw_vers -buildVersion 2>/dev/null || true)"
} > "$RUN_DIR/run-summary.txt"

{
  echo "target_dir=$TARGET_DIR"
  /bin/ls -laeO@ "$TARGET_DIR" || true
  /usr/bin/xattr -lr "$TARGET_DIR" || true
  if command -v fileproviderctl >/dev/null 2>&1; then
    echo
    echo "=== fileproviderctl domains ==="
    fileproviderctl domain list || true
  fi
} > "$RUN_DIR/environment/target-dir-preflight.txt" 2>&1

LOG_STREAM="$RUN_DIR/log-stream-fileprovider.txt"
/usr/bin/log stream --style syslog --level debug --predicate "$PREDICATE" > "$LOG_STREAM" 2>&1 &
LOG_PID=$!

cleanup() {
  if kill -0 "$LOG_PID" >/dev/null 2>&1; then
    kill "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

for op in ${(z)$(mode_list)}; do
  echo "[*] operation: $op"
  run_one_operation "$op"
  sleep "${PACKET004_IMPORT_MOVE_PAUSE_SECONDS:-2}"
done

sleep 2
cleanup
trap - EXIT

/usr/bin/log show --style syslog --last "${LOG_SHOW_LAST:-8m}" --predicate "$PREDICATE" > "$RUN_DIR/log-show-fileprovider.txt" 2>&1 || true

rg -n "$TARGET_HIT_PATTERN" "$RUN_DIR/log-stream-fileprovider.txt" \
  | rg -v 'Filtering the log data using|predicate=' \
  > "$RUN_DIR/target-writer-helper-hits.txt" 2>/dev/null || true

rg -n "$SIBLING_HIT_PATTERN" "$RUN_DIR/log-stream-fileprovider.txt" \
  | rg -v 'Filtering the log data using|predicate=' \
  > "$RUN_DIR/sibling-provider-hits.txt" 2>/dev/null || true

{
  echo "run_dir=$RUN_DIR"
  echo "mode=$MODE"
  echo "target_dir=$TARGET_DIR"
  echo
  echo "=== operations ==="
  for summary in "$RUN_DIR"/operations/*/operation-summary.txt(N); do
    echo "--- $summary"
    sed -n '1,80p' "$summary" || true
  done
  echo
  echo "=== probe stdout/stderr ==="
  for op_dir in "$RUN_DIR"/operations/*(N); do
    echo "--- $op_dir/probe.stdout.txt"
    sed -n '1,120p' "$op_dir/probe.stdout.txt" || true
    echo "--- $op_dir/probe.stderr.txt"
    sed -n '1,80p' "$op_dir/probe.stderr.txt" || true
  done
  echo
  echo "=== target snapshots ==="
  for snap in "$RUN_DIR"/operations/*/target.after.txt(N); do
    echo "--- $snap"
    sed -n '1,80p' "$snap" || true
  done
  echo
  echo "=== fileprovider log hints ==="
  rg -n "FPDMoveWriterToProvider|_importURL|FPSandboxingURLWrapper|wrapperWithURL|fp_issueSandboxExtension|sandbox_extension_issue_file|sandbox extension|realpath|createItem|modifyItem|packet004|denied|deny|error" "$RUN_DIR/log-stream-fileprovider.txt" "$RUN_DIR/log-show-fileprovider.txt" > "$RUN_DIR/log-hits.txt" 2>&1 || true
  sed -n '1,160p' "$RUN_DIR/log-hits.txt" || true
  echo
  echo "=== target writer/helper hits ==="
  echo "source=live log stream for this run"
  echo "file=$RUN_DIR/target-writer-helper-hits.txt"
  echo "count=$(wc -l < "$RUN_DIR/target-writer-helper-hits.txt" | tr -d ' ')"
  sed -n '1,120p' "$RUN_DIR/target-writer-helper-hits.txt" || true
  echo
  echo "=== sibling provider/scoped-url hits ==="
  echo "source=live log stream for this run"
  echo "file=$RUN_DIR/sibling-provider-hits.txt"
  echo "count=$(wc -l < "$RUN_DIR/sibling-provider-hits.txt" | tr -d ' ')"
  sed -n '1,120p' "$RUN_DIR/sibling-provider-hits.txt" || true
  echo
  echo "Decision rule:"
  echo "- promote only if this run shows FPDMoveWriterToProvider/_importURL or wrapper/helper activity attributable to the controlled operation."
  echo "- if the files copy/move but logs show only generic FPFS/provider activity, classify this mode as non-promoting."
  echo "- if Finder modes fail with Automation/TCC prompts, rerun from Terminal after approving Finder automation."
  echo "- do not race source leaf transitions until a normal import/move workflow reaches the wrapper/helper path."
} > "$RUN_DIR/import-move-summary.txt" 2>&1

cat "$RUN_DIR/import-move-summary.txt"
