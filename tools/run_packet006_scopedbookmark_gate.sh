#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  ./tools/run_packet006_scopedbookmark_gate.sh [stable|symlink-leaf|symlink-race|dir-race|hardlink|sandbox-no-bookmark|unentitled-stable]

Purpose:
  Build and run the bounded Packet 006 ScopedBookmarkAgent runtime gate.
  This uses public security-scoped bookmark creation APIs against controlled
  files only. It does not probe protected folders.

Environment:
  RUN_DIR                                  override output directory
  APPLESAUCE_ARTIFACTS                     override artifacts root
  PACKET006_SCOPEDBOOKMARK_ITERATIONS      iteration count; race modes default 500, controls default 1
  PACKET006_SCOPEDBOOKMARK_RACE_SLEEP_US   race swap sleep in microseconds; default 100
  PACKET006_SCOPEDBOOKMARK_HARNESS_ROOT    override harness root
EOF
}

MODE="${1:-stable}"
case "$MODE" in
  stable|symlink-leaf|symlink-race|dir-race|hardlink|sandbox-no-bookmark|unentitled-stable)
    ;;
  *)
    usage
    exit 2
    ;;
esac

packet006_scopedbookmark_harness_root() {
  if [[ -n "${PACKET006_SCOPEDBOOKMARK_HARNESS_ROOT:-}" ]]; then
    if [[ -x "$PACKET006_SCOPEDBOOKMARK_HARNESS_ROOT/scripts/build.sh" ]]; then
      cd "$PACKET006_SCOPEDBOOKMARK_HARNESS_ROOT" && pwd
      return
    fi
    echo "PACKET006_SCOPEDBOOKMARK_HARNESS_ROOT is set but missing scripts/build.sh: $PACKET006_SCOPEDBOOKMARK_HARNESS_ROOT" >&2
    exit 2
  fi

  local root
  root="$(applesauce_root)/harnesses/packet006-scopedbookmark"
  if [[ -x "$root/scripts/build.sh" ]]; then
    cd "$root" && pwd
    return
  fi

  root="$(workspace_root)/harnesses/packet006-scopedbookmark"
  if [[ -x "$root/scripts/build.sh" ]]; then
    cd "$root" && pwd
    return
  fi

  cat >&2 <<'EOF'
Missing Packet 006 ScopedBookmark harness.

Expected one of:
  <applesauce>/harnesses/packet006-scopedbookmark
  <workspace>/harnesses/packet006-scopedbookmark

The directory must contain scripts/build.sh.
EOF
  exit 2
}

search_hits() {
  local pattern="$1"
  local out="$2"
  shift 2

  if command -v rg >/dev/null 2>&1; then
    rg -n "$pattern" "$@" > "$out" 2>&1 || true
    return
  fi

  /usr/bin/grep -En "$pattern" "$@" > "$out" 2>&1 || true
}

write_host_state() {
  local out="$1"
  mkdir -p "$out"
  sw_vers > "$out/sw_vers.txt" 2>&1 || true
  system_profiler SPSoftwareDataType > "$out/system_profiler-SPSoftwareDataType.txt" 2>&1 || true
  csrutil status > "$out/csrutil-status.txt" 2>&1 || true
  spctl --status > "$out/spctl-status.txt" 2>&1 || true
  xcodebuild -version > "$out/xcodebuild-version.txt" 2>&1 || true
}

summarize_jsonl() {
  local jsonl="$1"
  local out="$2"
  /usr/bin/awk '
    /"event":"summary"/ {
      print
      found=1
    }
    END {
      if (!found) print "missing summary event"
    }
  ' "$jsonl" > "$out" 2>&1 || true
}

WORKSPACE="$(workspace_root)"
ARTIFACTS="$(artifact_root)"
HARNESS="$(packet006_scopedbookmark_harness_root)"
STAMP="$(timestamp_utc)"
RUN_PARENT="$ARTIFACTS/runtime/packet006-scopedbookmark"
RUN_DIR="${RUN_DIR:-$RUN_PARENT/$(safe_sw_build_slug)-$STAMP-$MODE}"
APP_MODE="$MODE"
ENTITLEMENTS=1
ENTITLEMENT_PROFILE="full"

if [[ "$MODE" == "unentitled-stable" ]]; then
  APP_MODE="stable"
  ENTITLEMENTS=0
  ENTITLEMENT_PROFILE="none"
elif [[ "$MODE" == "sandbox-no-bookmark" ]]; then
  APP_MODE="stable"
  ENTITLEMENTS=1
  ENTITLEMENT_PROFILE="sandbox-only"
fi

ITERATIONS="${PACKET006_SCOPEDBOOKMARK_ITERATIONS:-}"
if [[ -z "$ITERATIONS" ]]; then
  case "$APP_MODE" in
    symlink-race|dir-race)
      ITERATIONS=500
      ;;
    *)
      ITERATIONS=1
      ;;
  esac
fi
RACE_SLEEP_US="${PACKET006_SCOPEDBOOKMARK_RACE_SLEEP_US:-100}"
PREDICATE='process == "ScopedBookmarkAgent" OR process == "Packet006ScopedBookmarkHarness" OR subsystem == "com.apple.FileURL" OR eventMessage CONTAINS[c] "File descriptor doesn" OR eventMessage CONTAINS[c] "bookmarked path" OR eventMessage CONTAINS[c] "real path" OR eventMessage CONTAINS[c] "security-scoped" OR eventMessage CONTAINS[c] "ScopedBookmarksAgent"'

require_cmd clang
require_cmd codesign
require_cmd /usr/bin/log
require_cmd sw_vers

mkdir -p "$RUN_DIR"/{metadata,logs}

{
  echo "workspace=$WORKSPACE"
  echo "artifacts=$ARTIFACTS"
  echo "harness=$HARNESS"
  echo "run_dir=$RUN_DIR"
  echo "mode=$MODE"
  echo "app_mode=$APP_MODE"
  echo "entitlements=$ENTITLEMENTS"
  echo "entitlement_profile=$ENTITLEMENT_PROFILE"
  echo "iterations=$ITERATIONS"
  echo "race_sleep_us=$RACE_SLEEP_US"
  date -u +"date_utc=%Y-%m-%dT%H:%M:%SZ"
} > "$RUN_DIR/metadata/run-context.txt"

write_host_state "$RUN_DIR/metadata/host-state"

echo "[*] workspace: $WORKSPACE"
echo "[*] harness: $HARNESS"
echo "[*] run dir: $RUN_DIR"
echo "[*] mode: $MODE"

BUILD_OUTPUT="$RUN_DIR/metadata/build-output.txt"
(
  cd "$HARNESS"
  PACKET006_SCOPEDBOOKMARK_ENTITLEMENTS="$ENTITLEMENTS" \
    PACKET006_SCOPEDBOOKMARK_ENTITLEMENT_PROFILE="$ENTITLEMENT_PROFILE" \
    ./scripts/build.sh
) > "$BUILD_OUTPUT" 2>&1

APP_EXE="$(/usr/bin/awk -F= '$1=="app_executable" {print $2}' "$BUILD_OUTPUT" | tail -1)"
APP_BUNDLE="$(/usr/bin/awk -F= '$1=="app" {print $2}' "$BUILD_OUTPUT" | tail -1)"
ENTITLEMENTS_PLIST="$(/usr/bin/awk -F= '$1=="entitlements" {print $2}' "$BUILD_OUTPUT" | tail -1)"
BUILT_PROFILE="$(/usr/bin/awk -F= '$1=="entitlement_profile" {print $2}' "$BUILD_OUTPUT" | tail -1)"

if [[ ! -x "$APP_EXE" ]]; then
  echo "built app executable missing: $APP_EXE" >&2
  cat "$BUILD_OUTPUT" >&2
  exit 1
fi

codesign -d --entitlements :- "$APP_BUNDLE" > "$RUN_DIR/metadata/app-entitlements.xml" 2>"$RUN_DIR/metadata/app-entitlements.stderr.txt" || true
codesign --verify --deep --strict "$APP_BUNDLE" > "$RUN_DIR/metadata/codesign-verify.stdout.txt" 2>"$RUN_DIR/metadata/codesign-verify.stderr.txt" || true
cp "$ENTITLEMENTS_PLIST" "$RUN_DIR/metadata/build-entitlements.plist" 2>/dev/null || true

/usr/bin/log stream --style compact --predicate "$PREDICATE" > "$RUN_DIR/logs/log-stream-scopedbookmark.txt" 2>&1 &
LOG_PID=$!
echo "$LOG_PID" > "$RUN_DIR/logs/log-stream.pid"
sleep 1

set +e
"$APP_EXE" \
  --mode "$APP_MODE" \
  --iterations "$ITERATIONS" \
  --race-sleep-us "$RACE_SLEEP_US" \
  > "$RUN_DIR/harness-output.jsonl" \
  2> "$RUN_DIR/harness-stderr.txt"
APP_STATUS=$?
set -e

sleep 1
if kill -0 "$LOG_PID" >/dev/null 2>&1; then
  kill "$LOG_PID" >/dev/null 2>&1 || true
  wait "$LOG_PID" >/dev/null 2>&1 || true
fi

echo "$APP_STATUS" > "$RUN_DIR/app-status.txt"
summarize_jsonl "$RUN_DIR/harness-output.jsonl" "$RUN_DIR/summary-event.json"
search_hits 'sample_to_resolved_identity_diverged":true|"bookmark_ok":false|"File descriptor doesn|bookmarked path|real path|error' "$RUN_DIR/hits.txt" "$RUN_DIR/harness-output.jsonl" "$RUN_DIR/harness-stderr.txt" "$RUN_DIR/logs/log-stream-scopedbookmark.txt"

{
  echo "# Packet 006 ScopedBookmark Runtime Gate"
  echo
  echo "- mode: \`$MODE\`"
  echo "- app mode: \`$APP_MODE\`"
  echo "- entitlements enabled: \`$ENTITLEMENTS\`"
  echo "- entitlement profile: \`$BUILT_PROFILE\`"
  echo "- app status: \`$APP_STATUS\`"
  echo "- iterations: \`$ITERATIONS\`"
  echo "- run dir: \`$RUN_DIR\`"
  echo
  echo "## Summary Event"
  echo
  sed -n '1,20p' "$RUN_DIR/summary-event.json"
  echo
  echo "## Decision Rule"
  echo
  echo "Promote only after comparing both 26.4 and 26.5 and seeing a behavior split consistent with the agent-internal fd/bookmark validation delta. Sample-to-resolved identity drift is a race signal only, not a vulnerability claim."
  echo
  echo "## Hits"
  echo
  sed -n '1,80p' "$RUN_DIR/hits.txt"
} > "$RUN_DIR/run-summary.md"

echo "$RUN_DIR"
exit "$APP_STATUS"
