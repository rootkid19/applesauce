#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
SCENARIO="${1:-background}"
FORCEQUIT_WINDOW_SECONDS="${FORCEQUIT_WINDOW_SECONDS:-90}"
PARENT_LINGER_SECONDS="${PARENT_LINGER_SECONDS:-180}"
HELPER_HOLD_SECONDS="${HELPER_HOLD_SECONDS:-240}"
SNAPSHOT_INTERVAL_SECONDS="${SNAPSHOT_INTERVAL_SECONDS:-5}"
LOG_SHOW_LAST="${LOG_SHOW_LAST:-10m}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RUN_DIR:-$ROOT/runs/$STAMP-forcequit-$SCENARIO}"

PARENT_APP="$BUILD/Parent.app"
HELPER_BG_APP="$BUILD/HelperBackground.app"
PIDJOB_HELPER_EXEC="$PARENT_APP/Contents/MacOS/HelperAgent"
PID_JOB_LABEL="com.chimera.lsstale.forcequit.pidjob.$STAMP"

case "$SCENARIO" in
  background|pidjob)
    ;;
  *)
    echo "usage: $0 [background|pidjob]" >&2
    exit 2
    ;;
esac

if [[ ! -x "$PARENT_APP/Contents/MacOS/ParentHarness" ]]; then
  "$ROOT/scripts/build.sh"
fi

mkdir -p "$RUN_DIR"

LOG_PREDICATE='process == "launchservicesd" && (eventMessage CONTAINS[c] "applicationCheckIn" OR eventMessage CONTAINS[c] "inheritApplicationSubprocesses" OR eventMessage CONTAINS[c] "AddPIDToSession" OR eventMessage CONTAINS[c] "DEATH" OR eventMessage CONTAINS[c] "SESSION-REMOVEAPP" OR eventMessage CONTAINS[c] "EXITED" OR eventMessage CONTAINS[c] "non-foreground child" OR eventMessage CONTAINS[c] "non-application process in its coalition" OR eventMessage CONTAINS[c] "adding exited application" OR eventMessage CONTAINS[c] "copyJobsLoadedByCoalition" OR eventMessage CONTAINS[c] "loaded job" OR eventMessage CONTAINS[c] "loaded jobs" OR eventMessage CONTAINS[c] "ForceQuit" OR eventMessage CONTAINS[c] "force quit" OR eventMessage CONTAINS[c] "quit" OR eventMessage CONTAINS[c] "LSStale" OR eventMessage CONTAINS[c] "HelperHarness" OR eventMessage CONTAINS[c] "HelperAgent")'
LOG_ALL_PREDICATE='process == "launchservicesd"'

cleanup() {
  if [[ -n "${LOG_PID:-}" ]]; then
    kill "$LOG_PID" 2>/dev/null || true
  fi
  if [[ -n "${LOG_ALL_PID:-}" ]]; then
    kill "$LOG_ALL_PID" 2>/dev/null || true
  fi
  if [[ -n "${LISTEN_PID:-}" ]]; then
    kill "$LISTEN_PID" 2>/dev/null || true
  fi
  if [[ "$SCENARIO" == "pidjob" && -f "$RUN_DIR/parent-first.pid" ]]; then
    local parent_pid
    parent_pid="$(tr -dc '0-9' < "$RUN_DIR/parent-first.pid")"
    if [[ -n "$parent_pid" ]]; then
      /bin/launchctl bootout "pid/$parent_pid" "$RUN_DIR/$PID_JOB_LABEL.plist" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

wait_for_file() {
  local file="$1"
  local timeout="$2"
  local start="$(date +%s)"
  while [[ ! -f "$file" ]]; do
    sleep 0.2
    if (( $(date +%s) - start >= timeout )); then
      return 1
    fi
  done
}

snapshot() {
  local label="$1"
  local out="$RUN_DIR/$label"
  mkdir -p "$out"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$out/timestamp.txt"

  lsappinfo list > "$out/lsappinfo-list.txt" 2>&1 || true
  lsappinfo processList > "$out/lsappinfo-processList.txt" 2>&1 || true
  lsappinfo find "bundleid=com.chimera.lsstale.Parent" > "$out/lsappinfo-find-parent.txt" 2>&1 || true
  lsappinfo info "com.chimera.lsstale.Parent" > "$out/lsappinfo-info-parent.txt" 2>&1 || true
  lsappinfo find "bundleid=com.chimera.lsstale.HelperBackground" > "$out/lsappinfo-find-helper-background.txt" 2>&1 || true
  lsappinfo info "com.chimera.lsstale.HelperBackground" > "$out/lsappinfo-info-helper-background.txt" 2>&1 || true

  for key in \
    kLSASNKey \
    kLSPIDKey \
    kLSParentASNKey \
    LSApplicationType \
    LSApplicationCoalitionIDKey \
    LSApplicationCoalitionPIDsKey \
    LSApplicationCoalitionNonApplicationPIDsKey \
    LSApplicationCoalitionNonForegroundApplicationPIDsKey \
    LSStoppedState \
    __kLSApplicationAllRelatedApplicationASNsArrayKey \
    __kLSApplicationExitedButHasRemainingCoalitionPIDsOrNonForegroundChildrenApplicationsKey \
    __kLSApplicationExitedTimeKey
  do
    local safe="${key//[^A-Za-z0-9_]/_}"
    lsappinfo info -only "$key" "com.chimera.lsstale.Parent" > "$out/lsappinfo-only-$safe-parent.txt" 2>&1 || true
    lsappinfo info -only "$key" "com.chimera.lsstale.HelperBackground" > "$out/lsappinfo-only-$safe-helper-background.txt" 2>&1 || true
  done

  ps -axo pid,ppid,pgid,sess,stat,comm,args > "$out/ps.txt" 2>&1 || true
  launchctl print "gui/$(id -u)" > "$out/launchctl-print-gui.txt" 2>&1 || true

  for pidfile in "$RUN_DIR"/*.pid(N); do
    local pid
    pid="$(tr -dc '0-9' < "$pidfile")"
    if [[ -n "$pid" ]]; then
      launchctl procinfo "$pid" > "$out/launchctl-procinfo-$pid.txt" 2>&1 || true
      launchctl print "pid/$pid" > "$out/launchctl-print-pid-$pid.txt" 2>&1 || true
    fi
  done
}

{
  echo "run_dir=$RUN_DIR"
  echo "scenario=$SCENARIO"
  echo "forcequit_window_seconds=$FORCEQUIT_WINDOW_SECONDS"
  echo "parent_linger_seconds=$PARENT_LINGER_SECONDS"
  echo "helper_hold_seconds=$HELPER_HOLD_SECONDS"
  echo "parent_app=$PARENT_APP"
  echo "helper_bg_app=$HELPER_BG_APP"
  echo "pid_job_label=$PID_JOB_LABEL"
} | tee "$RUN_DIR/run-summary.txt"

/usr/bin/log stream --debug --info --style syslog --predicate "$LOG_PREDICATE" > "$RUN_DIR/log-stream-launchservicesd-filtered.txt" 2>&1 &
LOG_PID=$!

/usr/bin/log stream --debug --info --style syslog --predicate "$LOG_ALL_PREDICATE" > "$RUN_DIR/log-stream-launchservicesd-all.txt" 2>&1 &
LOG_ALL_PID=$!

lsappinfo listen +all wait "$(( FORCEQUIT_WINDOW_SECONDS + 45 ))" > "$RUN_DIR/lsappinfo-listen.txt" 2>&1 &
LISTEN_PID=$!

snapshot before-launch

if [[ "$SCENARIO" == "background" ]]; then
  open -n "$PARENT_APP" --args \
    --phase first \
    --state-dir "$RUN_DIR" \
    --helper-kind background \
    --helper-app "$HELPER_BG_APP" \
    --hold-seconds "$HELPER_HOLD_SECONDS" \
    --linger \
    --linger-seconds "$PARENT_LINGER_SECONDS" \
    --activation-policy regular
else
  open -n "$PARENT_APP" --args \
    --phase first \
    --state-dir "$RUN_DIR" \
    --helper-kind pidjob \
    --helper-exec "$PIDJOB_HELPER_EXEC" \
    --pid-job-label "$PID_JOB_LABEL" \
    --hold-seconds "$HELPER_HOLD_SECONDS" \
    --job-start-wait-seconds 5 \
    --linger \
    --linger-seconds "$PARENT_LINGER_SECONDS" \
    --activation-policy regular
fi

wait_for_file "$RUN_DIR/parent-first.pid" 15 || true
sleep 3
snapshot after-parent-helper-start

cat <<EOF | tee -a "$RUN_DIR/run-summary.txt"

Manual action required now:
  Force quit LSStaleParent using Dock or Apple menu > Force Quit.

Acceptable paths:
  - Dock: Option-right-click LSStaleParent, choose Force Quit.
  - Apple menu: Force Quit..., select LSStaleParent, Force Quit.

Capture window: ${FORCEQUIT_WINDOW_SECONDS}s

EOF

end=$(( $(date +%s) + FORCEQUIT_WINDOW_SECONDS ))
i=0
while (( $(date +%s) < end )); do
  snapshot "during-forcequit-$i"
  sleep "$SNAPSHOT_INTERVAL_SECONDS"
  i=$(( i + 1 ))
done

snapshot after-forcequit-window

if [[ "$SCENARIO" != "background" ]]; then
  if [[ -f "$RUN_DIR/parent-first.pid" ]]; then
    parent_pid="$(tr -dc '0-9' < "$RUN_DIR/parent-first.pid")"
    if [[ -n "$parent_pid" ]]; then
      /bin/launchctl print "pid/$parent_pid" > "$RUN_DIR/pidjob-final-print.txt" 2>&1 || true
    fi
  fi
fi

/usr/bin/log show --debug --info --style syslog --last "$LOG_SHOW_LAST" --predicate "$LOG_ALL_PREDICATE" > "$RUN_DIR/log-show-launchservicesd-all.txt" 2>&1 || true
/usr/bin/log show --debug --info --style syslog --last "$LOG_SHOW_LAST" --predicate "$LOG_PREDICATE" > "$RUN_DIR/log-show-launchservicesd-filtered.txt" 2>&1 || true

echo "completed run_dir=$RUN_DIR" | tee -a "$RUN_DIR/run-summary.txt"
