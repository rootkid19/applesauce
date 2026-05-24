#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

ROOT="$(campaign_root)"
HARNESS="$ROOT/harnesses/ls-stale-state"
STAMP="$(timestamp_utc)"
RUN_PARENT="$ROOT/artifacts/runtime/ls-pidjob"
RUN_DIR="${RUN_DIR:-$RUN_PARENT/$(safe_sw_build_slug)-$STAMP-pidjob}"

require_cmd log
require_cmd lsappinfo
require_cmd launchctl

mkdir -p "$RUN_DIR/environment"

echo "[*] campaign root: $ROOT"
echo "[*] run dir: $RUN_DIR"

"$(applesauce_root)/tools/collect_campaign1_host_state.sh" "$RUN_DIR/environment/host-state" >/dev/null
"$HARNESS/scripts/build.sh"

(
  cd "$HARNESS"
  RUN_DIR="$RUN_DIR" \
  HOLD_SECONDS="${HOLD_SECONDS:-60}" \
  SECOND_LINGER_SECONDS="${SECOND_LINGER_SECONDS:-20}" \
  JOB_START_WAIT_SECONDS="${JOB_START_WAIT_SECONDS:-5}" \
  LOG_SHOW_LAST="${LOG_SHOW_LAST:-10m}" \
  "$HARNESS/scripts/run_same_bundle_relaunch.sh" pidjob
)

{
  echo "run_dir=$RUN_DIR"
  echo
  echo "=== pidjob proof ==="
  rg -n "pidjob|bootstrapped|launchctl-print-pidjob|rc=0|rc=" "$RUN_DIR" || true
  echo
  echo "=== promotion logs ==="
  rg -n "enableQuitReally|copyJobsLoadedByCoalition|PID domain job|loaded jobs|adding exited application|inheritApplicationSubprocesses|DEATH:" "$RUN_DIR" || true
  echo
  echo "=== LS properties ==="
  rg -n "__kLSApplicationExited|AllRelatedApplicationASNs|LSApplicationCoalition|LSLaunchDLabel" "$RUN_DIR"/after-first-exit "$RUN_DIR"/during-second-relaunch "$RUN_DIR"/final 2>/dev/null || true
} > "$RUN_DIR/pidjob-summary.txt" 2>&1

cat "$RUN_DIR/pidjob-summary.txt"
