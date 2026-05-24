#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

WORKSPACE="$(workspace_root)"
ARTIFACTS="$(artifact_root)"
HARNESS="$(harness_root)"
STAMP="$(timestamp_utc)"
RUN_PARENT="$ARTIFACTS/runtime/ls-stock-gate"
RUN_DIR="${RUN_DIR:-$RUN_PARENT/$(safe_sw_build_slug)-$STAMP-none}"
PLIST="/Library/Preferences/FeatureFlags/Domain/LaunchServices.plist"

require_cmd log
require_cmd lsappinfo

mkdir -p "$RUN_DIR/environment"

echo "[*] workspace: $WORKSPACE"
echo "[*] harness: $HARNESS"
echo "[*] run dir: $RUN_DIR"

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
    echo "Refusing to call this a clean stock gate while the plist exists."
    echo "Move it aside, reboot or restart launchservicesd, then rerun."
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
  HOLD_SECONDS="${HOLD_SECONDS:-45}" \
  SECOND_LINGER_SECONDS="${SECOND_LINGER_SECONDS:-15}" \
  JOB_START_WAIT_SECONDS="${JOB_START_WAIT_SECONDS:-3}" \
  LOG_SHOW_LAST="${LOG_SHOW_LAST:-8m}" \
  "$HARNESS/scripts/run_same_bundle_relaunch.sh" none
)

{
  echo "run_dir=$RUN_DIR"
  echo
  echo "=== quitreally ==="
  rg -n "enableQuitReally|quitreally" "$RUN_DIR" || true
  echo
  echo "=== migration ==="
  rg -n "adding exited application|inheritApplicationSubprocesses|HasNoChildApplicationsOrSubprocesses|DEATH:|copyJobsLoadedByCoalition" "$RUN_DIR" || true
} > "$RUN_DIR/stock-gate-summary.txt" 2>&1

cat "$RUN_DIR/stock-gate-summary.txt"
