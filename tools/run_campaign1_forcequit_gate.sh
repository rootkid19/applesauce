#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

WORKSPACE="$(workspace_root)"
ARTIFACTS="$(artifact_root)"
HARNESS="$(harness_root)"
STAMP="$(timestamp_utc)"
SCENARIO="${1:-background}"
RUN_PARENT="$ARTIFACTS/runtime/ls-forcequit-gate"
RUN_DIR="${RUN_DIR:-$RUN_PARENT/$(safe_sw_build_slug)-$STAMP-$SCENARIO}"
PLIST="/Library/Preferences/FeatureFlags/Domain/LaunchServices.plist"

case "$SCENARIO" in
  background|pidjob)
    ;;
  *)
    echo "usage: $0 [background|pidjob]" >&2
    exit 2
    ;;
esac

require_cmd log
require_cmd lsappinfo
require_cmd open

mkdir -p "$RUN_DIR/environment"

echo "[*] workspace: $WORKSPACE"
echo "[*] harness: $HARNESS"
echo "[*] run dir: $RUN_DIR"
echo "[*] scenario: $SCENARIO"

"$(applesauce_root)/tools/collect_campaign1_host_state.sh" "$RUN_DIR/environment/host-state" >/dev/null

{
  echo "FeatureFlags path: $PLIST"
  if [[ -e "$PLIST" ]]; then
    echo "present"
    ls -laeO@ "$PLIST" || true
    xattr -lr "$PLIST" || true
    shasum -a 256 "$PLIST" || true
    plutil -p "$PLIST" || true
    echo
    echo "Refusing to call this a clean stock force-quit gate while the plist exists."
    exit 3
  else
    echo "missing"
  fi
} > "$RUN_DIR/environment/LaunchServices.FeatureFlags.preflight.txt" 2>&1

if [[ -e "$PLIST" ]]; then
  cat "$RUN_DIR/environment/LaunchServices.FeatureFlags.preflight.txt"
  exit 3
fi

"$HARNESS/scripts/build.sh"

(
  cd "$HARNESS"
  RUN_DIR="$RUN_DIR" \
  FORCEQUIT_WINDOW_SECONDS="${FORCEQUIT_WINDOW_SECONDS:-90}" \
  PARENT_LINGER_SECONDS="${PARENT_LINGER_SECONDS:-180}" \
  HELPER_HOLD_SECONDS="${HELPER_HOLD_SECONDS:-240}" \
  SNAPSHOT_INTERVAL_SECONDS="${SNAPSHOT_INTERVAL_SECONDS:-5}" \
  LOG_SHOW_LAST="${LOG_SHOW_LAST:-10m}" \
  "$HARNESS/scripts/run_forcequit_manual.sh" "$SCENARIO"
)

{
  echo "run_dir=$RUN_DIR"
  echo "scenario=$SCENARIO"
  echo
  echo "=== force quit / death / liveness hints ==="
  HITS="$RUN_DIR/forcequit-gate-hits.txt"
  CANDIDATES=(
    "$RUN_DIR/lsappinfo-listen.txt"
    "$RUN_DIR/log-show-launchservicesd-filtered.txt"
    "$RUN_DIR/log-stream-launchservicesd-filtered.txt"
    "$RUN_DIR"/after-parent-helper-start/lsappinfo-only-*.txt(N)
    "$RUN_DIR"/during-forcequit-*/lsappinfo-only-*.txt(N)
    "$RUN_DIR"/after-forcequit-window/lsappinfo-only-*.txt(N)
  )
  rg -n "ForceQuit|force quit|DEATH:|SESSION-REMOVEAPP|EXITED|final termination|remaining coalition|non-foreground child|loaded job|copyJobsLoadedByCoalition|AllRelatedApplicationASNs|ExitedButHasRemaining|kLSNotifyApplicationAbnormalDeath|kLSNotifyApplicationDeath|LSExitStatus" "${CANDIDATES[@]}" > "$HITS" 2>&1 || true
  sed -n '1,80p' "$HITS" || true
  total_hits="$(wc -l < "$HITS" 2>/dev/null || echo 0)"
  if [[ "$total_hits" != "0" && "$total_hits" -gt 80 ]]; then
    echo "... truncated summary; full hits in $HITS"
  fi
  echo
  echo "=== parent/helper state files ==="
  find "$RUN_DIR" -maxdepth 2 -type f \( -name '*.pid' -o -name '*.done' -o -name 'state.log' -o -name 'run-summary.txt' \) -print || true
  echo
  echo "Decision rule:"
  echo "- compare this run against the same scenario on the other OS build."
  echo "- promote only if actual Dock/loginwindow force quit changes stale app-record retention, final-termination timing, or death-info consumption."
  echo "- otherwise park Packet 001 fully."
} > "$RUN_DIR/forcequit-gate-summary.txt" 2>&1

cat "$RUN_DIR/forcequit-gate-summary.txt"
