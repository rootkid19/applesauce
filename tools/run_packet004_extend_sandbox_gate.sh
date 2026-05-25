#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  ./tools/run_packet004_extend_sandbox_gate.sh list
  ./tools/run_packet004_extend_sandbox_gate.sh wrapper <file-url-or-path> [readonly|readwrite] [repeat]
  ./tools/run_packet004_extend_sandbox_gate.sh extend <file-url-or-path> <provider-id> <consumer-id> [repeat]

Purpose:
  list      - enumerate FileProvider daemon provider/domain state through FPDaemonConnection.
  wrapper   - call FPSandboxingURLWrapper locally; this reaches the changed helper without daemon routing.
  extend    - call FPDaemonConnection extendSandboxForFileURL; this is the Packet 004 reachability gate.

Notes:
  wrapper is a helper sanity check only. The meaningful Packet 004 route is extend.
  Use a controlled FileProvider-domain URL for extend. Normal files usually fail provider/domain resolution.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

MODE="$1"
case "$MODE" in
  list|wrapper|extend)
    ;;
  *)
    usage
    exit 2
    ;;
esac

packet004_harness_root() {
  if [[ -n "${PACKET004_EXTEND_HARNESS_ROOT:-}" ]]; then
    if [[ -x "$PACKET004_EXTEND_HARNESS_ROOT/scripts/build.sh" ]]; then
      cd "$PACKET004_EXTEND_HARNESS_ROOT" && pwd
      return
    fi
    echo "PACKET004_EXTEND_HARNESS_ROOT is set but missing scripts/build.sh: $PACKET004_EXTEND_HARNESS_ROOT" >&2
    exit 2
  fi

  local root
  root="$(applesauce_root)/harnesses/packet004-extend-sandbox"
  if [[ -x "$root/scripts/build.sh" ]]; then
    cd "$root" && pwd
    return
  fi

  root="$(workspace_root)/harnesses/packet004-extend-sandbox"
  if [[ -x "$root/scripts/build.sh" ]]; then
    cd "$root" && pwd
    return
  fi

  cat >&2 <<'EOF'
Missing Packet 004 extend-sandbox harness.

Expected one of:
  <applesauce>/harnesses/packet004-extend-sandbox
  <workspace>/harnesses/packet004-extend-sandbox

The directory must contain scripts/build.sh.
EOF
  exit 2
}

WORKSPACE="$(workspace_root)"
ARTIFACTS="$(artifact_root)"
HARNESS="$(packet004_harness_root)"
STAMP="$(timestamp_utc)"
RUN_PARENT="$ARTIFACTS/runtime/packet004-extend-sandbox"
RUN_DIR="${RUN_DIR:-$RUN_PARENT/$(safe_sw_build_slug)-$STAMP-$MODE}"
PREDICATE='process == "fileproviderd" OR process == "fileproviderctl" OR eventMessage CONTAINS[c] "sandbox extension" OR eventMessage CONTAINS[c] "realpath" OR eventMessage CONTAINS[c] "extendSandbox" OR eventMessage CONTAINS[c] "FileProvider"'

require_cmd clang
require_cmd log
require_cmd sw_vers

mkdir -p "$RUN_DIR/environment"

echo "[*] workspace: $WORKSPACE"
echo "[*] harness: $HARNESS"
echo "[*] run dir: $RUN_DIR"
echo "[*] mode: $MODE"

"$(applesauce_root)/tools/collect_campaign1_host_state.sh" "$RUN_DIR/environment/host-state" >/dev/null

"$HARNESS/scripts/build.sh" > "$RUN_DIR/build.txt" 2>&1

{
  echo "mode=$MODE"
  echo "argv=$*"
  echo "predicate=$PREDICATE"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RUN_DIR/run-summary.txt"

LOG_STREAM="$RUN_DIR/log-stream-fileprovider.txt"
log stream --style syslog --level debug --predicate "$PREDICATE" > "$LOG_STREAM" 2>&1 &
LOG_PID=$!

cleanup() {
  if kill -0 "$LOG_PID" >/dev/null 2>&1; then
    kill "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

set +e
"$HARNESS/scripts/run_probe.sh" "$@" > "$RUN_DIR/probe.stdout.txt" 2> "$RUN_DIR/probe.stderr.txt"
STATUS=$?
set -e

sleep 2
cleanup
trap - EXIT

log show --style syslog --last "${LOG_SHOW_LAST:-5m}" --predicate "$PREDICATE" > "$RUN_DIR/log-show-fileprovider.txt" 2>&1 || true

{
  echo "run_dir=$RUN_DIR"
  echo "mode=$MODE"
  echo "status=$STATUS"
  echo
  echo "=== probe stdout ==="
  sed -n '1,160p' "$RUN_DIR/probe.stdout.txt" || true
  echo
  echo "=== probe stderr ==="
  sed -n '1,80p' "$RUN_DIR/probe.stderr.txt" || true
  echo
  echo "=== fileprovider log hints ==="
  rg -n "sandbox extension|realpath|extendSandbox|wrapper|denied|deny|provider|domain|error" "$RUN_DIR/log-stream-fileprovider.txt" "$RUN_DIR/log-show-fileprovider.txt" > "$RUN_DIR/log-hits.txt" 2>&1 || true
  sed -n '1,120p' "$RUN_DIR/log-hits.txt" || true
  echo
  echo "Decision rule:"
  echo "- list should show whether FPDaemonConnection is usable from this process."
  echo "- wrapper should reach the changed helper locally; use it only as a helper sanity check."
  echo "- extend is the Packet 004 reachability gate. Promote to race testing only if it returns a wrapper or reaches the daemon path beyond entitlement/provider/domain checks."
  echo "- if extend is denied before wrapper creation, record the denial and park this direct broker path unless another local route supplies the required authority."
} > "$RUN_DIR/extend-sandbox-summary.txt" 2>&1

cat "$RUN_DIR/extend-sandbox-summary.txt"
exit "$STATUS"
