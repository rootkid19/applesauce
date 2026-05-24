#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
SCENARIO="${1:-background}"
HOLD_SECONDS="${HOLD_SECONDS:-45}"
SECOND_LINGER_SECONDS="${SECOND_LINGER_SECONDS:-15}"
LISTEN_SECONDS="${LISTEN_SECONDS:-$(( HOLD_SECONDS + SECOND_LINGER_SECONDS + 35 ))}"
LOG_SHOW_LAST="${LOG_SHOW_LAST:-8m}"
JOB_START_WAIT_SECONDS="${JOB_START_WAIT_SECONDS:-1}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RUN_DIR:-$ROOT/runs/$STAMP-$SCENARIO}"

PARENT_APP="$BUILD/Parent.app"
HELPER_BG_APP="$BUILD/HelperBackground.app"
HELPER_FG_APP="$BUILD/HelperForeground.app"
INBUNDLE_HELPER_EXEC="$PARENT_APP/Contents/Helpers/HelperHarness"
PIDJOB_HELPER_EXEC="$PARENT_APP/Contents/MacOS/HelperAgent"
LAUNCH_AGENT_LABEL="com.chimera.lsstale.launchagent.$STAMP"
PID_DOMAIN_LABEL="com.chimera.lsstale.piddomain.$STAMP"
PID_JOB_LABEL="com.chimera.lsstale.Parent.helper.$STAMP"
SUBMIT_LABEL="com.chimera.lsstale.submit.$STAMP"

case "$SCENARIO" in
  background)
    HELPER_KIND="background"
    HELPER_APP="$HELPER_BG_APP"
    ;;
  foreground)
    HELPER_KIND="foreground"
    HELPER_APP="$HELPER_FG_APP"
    HELPER_EXEC=""
    ;;
  subprocess)
    HELPER_KIND="subprocess"
    HELPER_APP=""
    HELPER_EXEC="$INBUNDLE_HELPER_EXEC"
    ;;
  forkhold)
    HELPER_KIND="forkhold"
    HELPER_APP=""
    HELPER_EXEC=""
    ;;
  launchagent)
    HELPER_KIND="launchagent"
    HELPER_APP=""
    HELPER_EXEC="$INBUNDLE_HELPER_EXEC"
    ;;
  piddomain)
    HELPER_KIND="piddomain"
    HELPER_APP=""
    HELPER_EXEC="$INBUNDLE_HELPER_EXEC"
    ;;
  pidjob)
    HELPER_KIND="pidjob"
    HELPER_APP=""
    HELPER_EXEC="$PIDJOB_HELPER_EXEC"
    ;;
  submit)
    HELPER_KIND="submit"
    HELPER_APP=""
    HELPER_EXEC="$INBUNDLE_HELPER_EXEC"
    ;;
  none)
    HELPER_KIND="none"
    HELPER_APP=""
    HELPER_EXEC=""
    ;;
  *)
    echo "usage: $0 [background|foreground|subprocess|forkhold|launchagent|piddomain|pidjob|submit|none]" >&2
    exit 2
    ;;
esac

if [[ "$SCENARIO" == "background" ]]; then
  HELPER_EXEC=""
fi

if [[ ! -x "$PARENT_APP/Contents/MacOS/ParentHarness" ]]; then
  "$ROOT/scripts/build.sh"
fi

mkdir -p "$RUN_DIR"

LOG_PREDICATE='process == "launchservicesd" && (eventMessage CONTAINS[c] "applicationCheckIn" OR eventMessage CONTAINS[c] "inheritApplicationSubprocesses" OR eventMessage CONTAINS[c] "AddPIDToSession" OR eventMessage CONTAINS[c] "DEATH" OR eventMessage CONTAINS[c] "SESSION-REMOVEAPP" OR eventMessage CONTAINS[c] "EXITED" OR eventMessage CONTAINS[c] "non-foreground child" OR eventMessage CONTAINS[c] "non-application process in its coalition" OR eventMessage CONTAINS[c] "adding exited application" OR eventMessage CONTAINS[c] "copyJobsLoadedByCoalition" OR eventMessage CONTAINS[c] "loaded job" OR eventMessage CONTAINS[c] "loaded jobs" OR eventMessage CONTAINS[c] "Launch job monitor" OR eventMessage CONTAINS[c] "OSLaunchdJob" OR eventMessage CONTAINS[c] "PID domain job" OR eventMessage CONTAINS[c] "pidjob" OR eventMessage CONTAINS[c] "forkhold" OR eventMessage CONTAINS[c] "com.chimera.lsstale" OR eventMessage CONTAINS[c] "LSStale" OR eventMessage CONTAINS[c] "HelperHarness" OR eventMessage CONTAINS[c] "HelperAgent")'
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
  if [[ "${HELPER_KIND:-}" == "launchagent" ]]; then
    /bin/launchctl bootout "gui/$(id -u)" "$RUN_DIR/$LAUNCH_AGENT_LABEL.plist" >/dev/null 2>&1 || true
  fi
  if [[ "${HELPER_KIND:-}" == "piddomain" && -f "$RUN_DIR/parent-first.pid" ]]; then
    local parent_pid
    parent_pid="$(tr -dc '0-9' < "$RUN_DIR/parent-first.pid")"
    if [[ -n "$parent_pid" ]]; then
      /bin/launchctl bootout "pid/$parent_pid" "$RUN_DIR/$PID_DOMAIN_LABEL.plist" >/dev/null 2>&1 || true
    fi
  fi
  if [[ "${HELPER_KIND:-}" == "pidjob" && -f "$RUN_DIR/parent-first.pid" ]]; then
    local parent_pid
    parent_pid="$(tr -dc '0-9' < "$RUN_DIR/parent-first.pid")"
    if [[ -n "$parent_pid" ]]; then
      /bin/launchctl bootout "pid/$parent_pid" "$RUN_DIR/$PID_JOB_LABEL.plist" >/dev/null 2>&1 || true
    fi
  fi
  if [[ "${HELPER_KIND:-}" == "submit" ]]; then
    /bin/launchctl remove "$SUBMIT_LABEL" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

/usr/bin/log stream --debug --info --style syslog --predicate "$LOG_PREDICATE" > "$RUN_DIR/log-stream-launchservicesd-filtered.txt" 2>&1 &
LOG_PID=$!

/usr/bin/log stream --debug --info --style syslog --predicate "$LOG_ALL_PREDICATE" > "$RUN_DIR/log-stream-launchservicesd-all.txt" 2>&1 &
LOG_ALL_PID=$!

lsappinfo listen +all wait "$LISTEN_SECONDS" > "$RUN_DIR/lsappinfo-listen.txt" 2>&1 &
LISTEN_PID=$!

collect_environment() {
  local out="$RUN_DIR/environment"
  mkdir -p "$out"

  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$out/timestamp.txt"
  sw_vers > "$out/sw_vers.txt" 2>&1 || true
  uname -a > "$out/uname.txt" 2>&1 || true
  id > "$out/id.txt" 2>&1 || true
  sysctl kern.osversion kern.osproductversion > "$out/sysctl-os.txt" 2>&1 || true
  ls -laeO@ "$BUILD" "$PARENT_APP" "$HELPER_BG_APP" "$HELPER_FG_APP" > "$out/bundle-ls.txt" 2>&1 || true
  xattr -lr "$PARENT_APP" "$HELPER_BG_APP" "$HELPER_FG_APP" > "$out/bundle-xattrs.txt" 2>&1 || true
  codesign -dv --verbose=4 "$PARENT_APP" > "$out/codesign-parent.txt" 2>&1 || true
  codesign -dv --verbose=4 "$PIDJOB_HELPER_EXEC" > "$out/codesign-helper-agent.txt" 2>&1 || true
  codesign -dv --verbose=4 "$HELPER_BG_APP" > "$out/codesign-helper-background.txt" 2>&1 || true
  codesign -dv --verbose=4 "$HELPER_FG_APP" > "$out/codesign-helper-foreground.txt" 2>&1 || true
  spctl --assess --type execute --verbose=4 "$PARENT_APP" > "$out/spctl-parent.txt" 2>&1 || true
  spctl --assess --type execute --verbose=4 "$PIDJOB_HELPER_EXEC" > "$out/spctl-helper-agent.txt" 2>&1 || true
  spctl --assess --type execute --verbose=4 "$HELPER_BG_APP" > "$out/spctl-helper-background.txt" 2>&1 || true
  spctl --assess --type execute --verbose=4 "$HELPER_FG_APP" > "$out/spctl-helper-foreground.txt" 2>&1 || true
}

snapshot() {
  local label="$1"
  local out="$RUN_DIR/$label"
  mkdir -p "$out"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$out/timestamp.txt"

  lsappinfo list > "$out/lsappinfo-list.txt" 2>&1 || true
  lsappinfo processList > "$out/lsappinfo-processList.txt" 2>&1 || true
  lsappinfo metainfo > "$out/lsappinfo-metainfo.txt" 2>&1 || true
  launchctl print "gui/$(id -u)" > "$out/launchctl-print-gui.txt" 2>&1 || true
  if [[ "$HELPER_KIND" == "launchagent" ]]; then
    launchctl print "gui/$(id -u)/$LAUNCH_AGENT_LABEL" > "$out/launchctl-print-launchagent.txt" 2>&1 || true
    launchctl blame "gui/$(id -u)/$LAUNCH_AGENT_LABEL" > "$out/launchctl-blame-launchagent.txt" 2>&1 || true
  fi
  if [[ "$HELPER_KIND" == "piddomain" && -f "$RUN_DIR/parent-first.pid" ]]; then
    local parent_pid
    parent_pid="$(tr -dc '0-9' < "$RUN_DIR/parent-first.pid")"
    if [[ -n "$parent_pid" ]]; then
      launchctl print "pid/$parent_pid" > "$out/launchctl-print-piddomain-parent.txt" 2>&1 || true
      launchctl blame "pid/$parent_pid/$PID_DOMAIN_LABEL" > "$out/launchctl-blame-piddomain-parent.txt" 2>&1 || true
    fi
  fi
  if [[ "$HELPER_KIND" == "pidjob" && -f "$RUN_DIR/parent-first.pid" ]]; then
    local parent_pid
    parent_pid="$(tr -dc '0-9' < "$RUN_DIR/parent-first.pid")"
    if [[ -n "$parent_pid" ]]; then
      launchctl print "pid/$parent_pid" > "$out/launchctl-print-pidjob-parent.txt" 2>&1 || true
      launchctl blame "pid/$parent_pid/$PID_JOB_LABEL" > "$out/launchctl-blame-pidjob-parent.txt" 2>&1 || true
    fi
  fi
  if [[ "$HELPER_KIND" == "submit" ]]; then
    launchctl print "gui/$(id -u)/$SUBMIT_LABEL" > "$out/launchctl-print-submit.txt" 2>&1 || true
    launchctl blame "gui/$(id -u)/$SUBMIT_LABEL" > "$out/launchctl-blame-submit.txt" 2>&1 || true
  fi
  ps -axo pid,ppid,pgid,sess,stat,comm,args > "$out/ps.txt" 2>&1 || true

  local keys=(
    kLSASNKey
    kLSPIDKey
    kLSParentASNKey
    kLSBundlePathKey
    LSApplicationType
    LSLaunchedByLaunchServices
    LSLaunchedWithLaunchD
    LSApplicationCoalitionIDKey
    LSApplicationMemberCoalitionIDKey
    LSApplicationCoalitionPIDsKey
    LSApplicationCoalitionNonApplicationPIDsKey
    LSApplicationCoalitionNonForegroundApplicationPIDsKey
    LSApplicationReadyToBeFrontableKey
    LSApplicationHasRegistered
    LSStoppedState
    LSLaunchDLabel
    __kLSApplicationAllRelatedApplicationASNsArrayKey
    __kLSApplicationExitedButHasRemainingCoalitionPIDsOrNonForegroundChildrenApplicationsKey
    __kLSApplicationExitedTimeKey
  )

  for bid in com.chimera.lsstale.Parent com.chimera.lsstale.HelperBackground com.chimera.lsstale.HelperForeground; do
    local safe="${bid//./_}"
    lsappinfo find "bundleid=$bid" > "$out/lsappinfo-find-$safe.txt" 2>&1 || true
    lsappinfo info "$bid" > "$out/lsappinfo-info-$safe.txt" 2>&1 || true
    for key in "${keys[@]}"; do
      local key_safe="${key//[^A-Za-z0-9_]/_}"
      lsappinfo info -only "$key" "$bid" > "$out/lsappinfo-only-$key_safe-$safe.txt" 2>&1 || true
    done
  done

  for pidfile in "$RUN_DIR"/*.pid(N); do
    local pid="$(tr -dc '0-9' < "$pidfile")"
    if [[ -n "$pid" ]]; then
      launchctl procinfo "$pid" > "$out/launchctl-procinfo-$pid.txt" 2>&1 || true
      launchctl print "pid/$pid" > "$out/launchctl-print-pid-$pid.txt" 2>&1 || true
    fi
  done
}

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

echo "run_dir=$RUN_DIR" | tee "$RUN_DIR/run-summary.txt"
echo "scenario=$SCENARIO helper_kind=$HELPER_KIND hold=$HOLD_SECONDS" | tee -a "$RUN_DIR/run-summary.txt"
echo "listen_seconds=$LISTEN_SECONDS log_show_last=$LOG_SHOW_LAST" | tee -a "$RUN_DIR/run-summary.txt"
echo "job_start_wait_seconds=$JOB_START_WAIT_SECONDS" | tee -a "$RUN_DIR/run-summary.txt"
echo "parent_app=$PARENT_APP" | tee -a "$RUN_DIR/run-summary.txt"
echo "helper_app=$HELPER_APP" | tee -a "$RUN_DIR/run-summary.txt"
echo "helper_exec=$HELPER_EXEC" | tee -a "$RUN_DIR/run-summary.txt"
echo "launch_agent_label=$LAUNCH_AGENT_LABEL" | tee -a "$RUN_DIR/run-summary.txt"
echo "pid_domain_label=$PID_DOMAIN_LABEL" | tee -a "$RUN_DIR/run-summary.txt"
echo "pid_job_label=$PID_JOB_LABEL" | tee -a "$RUN_DIR/run-summary.txt"
echo "submit_label=$SUBMIT_LABEL" | tee -a "$RUN_DIR/run-summary.txt"

collect_environment
snapshot before

if [[ "$HELPER_KIND" == "none" ]]; then
  open -n "$PARENT_APP" --args \
    --phase first \
    --state-dir "$RUN_DIR" \
    --helper-kind none
elif [[ "$HELPER_KIND" == "subprocess" ]]; then
  open -n "$PARENT_APP" --args \
    --phase first \
    --state-dir "$RUN_DIR" \
    --helper-kind subprocess \
    --helper-exec "$HELPER_EXEC" \
    --hold-seconds "$HOLD_SECONDS"
elif [[ "$HELPER_KIND" == "forkhold" ]]; then
  open -n "$PARENT_APP" --args \
    --phase first \
    --state-dir "$RUN_DIR" \
    --helper-kind forkhold \
    --hold-seconds "$HOLD_SECONDS"
elif [[ "$HELPER_KIND" == "launchagent" ]]; then
  open -n "$PARENT_APP" --args \
    --phase first \
    --state-dir "$RUN_DIR" \
    --helper-kind launchagent \
    --helper-exec "$HELPER_EXEC" \
    --launch-agent-label "$LAUNCH_AGENT_LABEL" \
    --hold-seconds "$HOLD_SECONDS"
elif [[ "$HELPER_KIND" == "piddomain" ]]; then
  open -n "$PARENT_APP" --args \
    --phase first \
    --state-dir "$RUN_DIR" \
    --helper-kind piddomain \
    --helper-exec "$HELPER_EXEC" \
    --pid-domain-label "$PID_DOMAIN_LABEL" \
    --hold-seconds "$HOLD_SECONDS" \
    --job-start-wait-seconds "$JOB_START_WAIT_SECONDS"
elif [[ "$HELPER_KIND" == "pidjob" ]]; then
  open -n "$PARENT_APP" --args \
    --phase first \
    --state-dir "$RUN_DIR" \
    --helper-kind pidjob \
    --helper-exec "$HELPER_EXEC" \
    --pid-job-label "$PID_JOB_LABEL" \
    --hold-seconds "$HOLD_SECONDS" \
    --job-start-wait-seconds "$JOB_START_WAIT_SECONDS"
elif [[ "$HELPER_KIND" == "submit" ]]; then
  open -n "$PARENT_APP" --args \
    --phase first \
    --state-dir "$RUN_DIR" \
    --helper-kind submit \
    --helper-exec "$HELPER_EXEC" \
    --submit-label "$SUBMIT_LABEL" \
    --hold-seconds "$HOLD_SECONDS" \
    --job-start-wait-seconds "$JOB_START_WAIT_SECONDS"
else
  open -n "$PARENT_APP" --args \
    --phase first \
    --state-dir "$RUN_DIR" \
    --helper-kind "$HELPER_KIND" \
    --helper-app "$HELPER_APP" \
    --hold-seconds "$HOLD_SECONDS"
fi

wait_for_file "$RUN_DIR/parent-first.done" 10 || true
sleep 2
snapshot after-first-exit

open -n "$PARENT_APP" --args \
  --phase second \
  --state-dir "$RUN_DIR" \
  --helper-kind none \
  --linger-seconds "$SECOND_LINGER_SECONDS"

sleep 2
snapshot during-second-relaunch

wait_for_file "$RUN_DIR/parent-second.done" 15 || true
sleep 2
snapshot after-second-relaunch

sleep 3
snapshot final

if [[ "$HELPER_KIND" != "none" ]]; then
  wait_for_file "$RUN_DIR/helper-$HELPER_KIND.done" "$(( HOLD_SECONDS + 10 ))" || true
fi

if [[ "$HELPER_KIND" == "launchagent" ]]; then
  /bin/launchctl print "gui/$(id -u)/$LAUNCH_AGENT_LABEL" > "$RUN_DIR/launchagent-final-print.txt" 2>&1 || true
  /bin/launchctl bootout "gui/$(id -u)" "$RUN_DIR/$LAUNCH_AGENT_LABEL.plist" > "$RUN_DIR/launchagent-bootout.txt" 2>&1 || true
fi

if [[ "$HELPER_KIND" == "piddomain" ]]; then
  if [[ -f "$RUN_DIR/parent-first.pid" ]]; then
    parent_pid="$(tr -dc '0-9' < "$RUN_DIR/parent-first.pid")"
    if [[ -n "$parent_pid" ]]; then
      /bin/launchctl print "pid/$parent_pid" > "$RUN_DIR/piddomain-final-print.txt" 2>&1 || true
      /bin/launchctl bootout "pid/$parent_pid" "$RUN_DIR/$PID_DOMAIN_LABEL.plist" > "$RUN_DIR/piddomain-bootout.txt" 2>&1 || true
    fi
  fi
fi

if [[ "$HELPER_KIND" == "pidjob" ]]; then
  if [[ -f "$RUN_DIR/parent-first.pid" ]]; then
    parent_pid="$(tr -dc '0-9' < "$RUN_DIR/parent-first.pid")"
    if [[ -n "$parent_pid" ]]; then
      /bin/launchctl print "pid/$parent_pid" > "$RUN_DIR/pidjob-final-print.txt" 2>&1 || true
      /bin/launchctl bootout "pid/$parent_pid" "$RUN_DIR/$PID_JOB_LABEL.plist" > "$RUN_DIR/pidjob-bootout.txt" 2>&1 || true
    fi
  fi
fi

if [[ "$HELPER_KIND" == "submit" ]]; then
  /bin/launchctl print "gui/$(id -u)/$SUBMIT_LABEL" > "$RUN_DIR/submit-final-print.txt" 2>&1 || true
  /bin/launchctl remove "$SUBMIT_LABEL" > "$RUN_DIR/submit-remove.txt" 2>&1 || true
fi

/usr/bin/log show --debug --info --style syslog --last "$LOG_SHOW_LAST" --predicate "$LOG_ALL_PREDICATE" > "$RUN_DIR/log-show-launchservicesd-all.txt" 2>&1 || true
/usr/bin/log show --debug --info --style syslog --last "$LOG_SHOW_LAST" --predicate "$LOG_PREDICATE" > "$RUN_DIR/log-show-launchservicesd-filtered.txt" 2>&1 || true

echo "completed run_dir=$RUN_DIR" | tee -a "$RUN_DIR/run-summary.txt"
