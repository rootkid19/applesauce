#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  ./tools/run_packet004_importdomain_gate.sh [normal|symlink-leaf|race]

Purpose:
  Build a minimal FileProvider-extension-hosting app bundle and call
  +[NSFileProviderManager importDomain:fromDirectoryAtURL:completionHandler:]
  with a controlled directory URL.

Modes:
  normal        pass a normal directory.
  symlink-leaf  pass a symlink whose leaf resolves to a directory.
  race          pass a symlink leaf while a local swap loop retargets it inside the run directory.

  Environment:
  RUN_DIR                         override output directory.
  APPLESAUCE_ARTIFACTS            override artifacts root.
  PACKET004_IMPORTDOMAIN_TIMEOUT  app completion timeout in seconds; default 60.
  PACKET004_KEEP_DOMAIN=1         do not remove the temporary domain after the run.
  PACKET004_KEEP_PLUGIN=1         do not unregister the temporary FileProvider extension.
  PACKET004_SWIZZLE=0             disable in-process caller method probes.
  PACKET004_INSTRUMENT=lldb       run under LLDB with symbolic breakpoints instead of app swizzling.
EOF
}

MODE="${1:-normal}"
case "$MODE" in
  normal|symlink-leaf|race)
    ;;
  *)
    usage
    exit 2
    ;;
esac

packet004_importdomain_harness_root() {
  if [[ -n "${PACKET004_IMPORTDOMAIN_HARNESS_ROOT:-}" ]]; then
    if [[ -x "$PACKET004_IMPORTDOMAIN_HARNESS_ROOT/scripts/build.sh" ]]; then
      cd "$PACKET004_IMPORTDOMAIN_HARNESS_ROOT" && pwd
      return
    fi
    echo "PACKET004_IMPORTDOMAIN_HARNESS_ROOT is set but missing scripts/build.sh: $PACKET004_IMPORTDOMAIN_HARNESS_ROOT" >&2
    exit 2
  fi

  local root
  root="$(applesauce_root)/harnesses/packet004-importdomain"
  if [[ -x "$root/scripts/build.sh" ]]; then
    cd "$root" && pwd
    return
  fi

  root="$(workspace_root)/harnesses/packet004-importdomain"
  if [[ -x "$root/scripts/build.sh" ]]; then
    cd "$root" && pwd
    return
  fi

  cat >&2 <<'EOF'
Missing Packet 004 importDomain harness.

Expected one of:
  <applesauce>/harnesses/packet004-importdomain
  <workspace>/harnesses/packet004-importdomain

The directory must contain scripts/build.sh.
EOF
  exit 2
}

write_path_snapshot() {
  local label="$1"
  local path="$2"
  local out="$3"
  {
    echo "label=$label"
    echo "path=$path"
    if [[ -L "$path" ]]; then
      echo "is_symlink=1"
      echo "readlink=$(readlink "$path" 2>/dev/null || true)"
    else
      echo "is_symlink=0"
    fi
    if [[ -e "$path" || -L "$path" ]]; then
      /bin/ls -laeO@ "$path" || true
      /usr/bin/stat -f 'lstat.dev=%d lstat.ino=%i lstat.mode=%p lstat.size=%z lstat.mtime=%m lstat.type=%HT' "$path" || true
      if [[ -e "$path" ]]; then
        /usr/bin/stat -L -f 'stat.dev=%d stat.ino=%i stat.mode=%p stat.size=%z stat.mtime=%m stat.type=%HT' "$path" || true
      fi
      /usr/bin/xattr -lr "$path" || true
    else
      echo "exists=0"
    fi
  } > "$out" 2>&1
}

prepare_controlled_tree() {
  local root="$1"
  mkdir -p "$root"

  case "$MODE" in
    normal)
      IMPORT_URL="$root/normal-source"
      mkdir -p "$IMPORT_URL/child"
      print -r -- "packet004 normal importDomain control" > "$IMPORT_URL/root.txt"
      print -r -- "packet004 normal child" > "$IMPORT_URL/child/child.txt"
      ;;
    symlink-leaf)
      SYMLINK_TARGET="$root/symlink-target"
      IMPORT_URL="$root/symlink-leaf"
      mkdir -p "$SYMLINK_TARGET/child"
      print -r -- "packet004 symlink-leaf target" > "$SYMLINK_TARGET/root.txt"
      print -r -- "packet004 symlink-leaf child" > "$SYMLINK_TARGET/child/child.txt"
      rm -f "$IMPORT_URL"
      ln -s "$SYMLINK_TARGET" "$IMPORT_URL"
      ;;
    race)
      RACE_A="$root/race-a"
      RACE_B="$root/race-b"
      IMPORT_URL="$root/race-leaf"
      mkdir -p "$RACE_A" "$RACE_B"
      print -r -- "packet004 race target A" > "$RACE_A/root.txt"
      print -r -- "packet004 race target B" > "$RACE_B/root.txt"
      rm -f "$IMPORT_URL"
      ln -s "$RACE_A" "$IMPORT_URL"
      ;;
  esac
}

start_race_swapper() {
  if [[ "$MODE" != "race" ]]; then
    RACE_PID=""
    return
  fi

  (
    i=0
    while true; do
      rm -f "$IMPORT_URL"
      if (( i % 2 == 0 )); then
        ln -s "$RACE_A" "$IMPORT_URL"
      else
        ln -s "$RACE_B" "$IMPORT_URL"
      fi
      i=$((i + 1))
      sleep "${PACKET004_RACE_SLEEP:-0.005}"
    done
  ) > "$RUN_DIR/race-swapper.stdout.txt" 2> "$RUN_DIR/race-swapper.stderr.txt" &
  RACE_PID=$!
  echo "$RACE_PID" > "$RUN_DIR/race-swapper.pid"
}

stop_race_swapper() {
  if [[ -n "${RACE_PID:-}" ]] && kill -0 "$RACE_PID" >/dev/null 2>&1; then
    kill "$RACE_PID" >/dev/null 2>&1 || true
    wait "$RACE_PID" >/dev/null 2>&1 || true
  fi
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

write_manual_lldb() {
  local out="$1"
  cat > "$out" <<EOF
Manual LLDB fallback for Packet 004 importDomain caller-process probes

Use this if SIP, DTrace, or other external probes block symbol instrumentation.
Run from a normal Terminal on the target OS. For external LLDB probing, disable
the app's in-process swizzles so the FileProvider method IMPs remain untouched.

App executable:
  $APP_EXE

Suggested launch:
  lldb -- "$APP_EXE" --mode "$MODE" --directory "$IMPORT_URL" --domain-id "$DOMAIN_ID" --domain-name "$DOMAIN_NAME" --timeout "${PACKET004_IMPORTDOMAIN_TIMEOUT:-60}" --no-swizzle

Breakpoints:
  breakpoint set -n '+[FPSandboxingURLWrapper wrapperWithURL:readonly:error:]'
  breakpoint set -n '+[FPSandboxingURLWrapper wrapperWithURL:extensionClass:error:]'
  breakpoint set -n '-[FPSandboxingURLWrapper initWithURL:extensionClass:report:error:]'
  breakpoint set -n '-[NSURL(FPAdditions) fp_issueSandboxExtensionOfClass:report:error:]'

On arm64/arm64e Objective-C calls, x0 is self, x1 is _cmd, x2 is the first
explicit argument. At wrapper breakpoints, inspect the URL with:
  po (id)\$x2
  po [(id)\$x2 path]
  bt

At fp_issueSandboxExtensionOfClass:report:error:, inspect the receiver URL:
  po (id)\$x0
  po [(id)\$x0 path]
  p (char *)\$x2
  bt

Known static offsets for manual address breakpoints if symbols are unavailable:
  26.4 fp_issueSandboxExtensionOfClass:report:error: 0x199dbf42c
  26.5 fp_issueSandboxExtensionOfClass:report:error: 0x199e2d42c
  26.4 wrapperWithURL:readonly:error: 0x199df98b8
  26.5 wrapperWithURL:readonly:error: 0x199e67a34
  26.4 addDomain import wrapper send: 0x199e74850
  26.5 addDomain import wrapper send: 0x199ee2a44
EOF
}

write_lldb_command_file() {
  local out="$1"
  cat > "$out" <<EOF
target create "$APP_EXE"
breakpoint set -n '+[FPSandboxingURLWrapper wrapperWithURL:readonly:error:]'
breakpoint set -n '+[FPSandboxingURLWrapper wrapperWithURL:extensionClass:error:]'
breakpoint set -n '-[FPSandboxingURLWrapper initWithURL:extensionClass:report:error:]'
breakpoint set -n '-[NSURL(FPAdditions) fp_issueSandboxExtensionOfClass:report:error:]'
breakpoint command add 1 -s command -o 'po (id)\$x2' -o 'po [(id)\$x2 path]' -o 'bt' -o 'continue'
breakpoint command add 2 -s command -o 'po (id)\$x2' -o 'po [(id)\$x2 path]' -o 'p (char *)\$x3' -o 'bt' -o 'continue'
breakpoint command add 3 -s command -o 'po (id)\$x2' -o 'po [(id)\$x2 path]' -o 'p (char *)\$x3' -o 'bt' -o 'continue'
breakpoint command add 4 -s command -o 'po (id)\$x0' -o 'po [(id)\$x0 path]' -o 'p (char *)\$x2' -o 'bt' -o 'continue'
settings set target.run-args --mode "$MODE" --directory "$IMPORT_URL" --domain-id "$DOMAIN_ID" --domain-name "$DOMAIN_NAME" --timeout "${PACKET004_IMPORTDOMAIN_TIMEOUT:-60}" --no-swizzle
run
quit
EOF
}

WORKSPACE="$(workspace_root)"
ARTIFACTS="$(artifact_root)"
HARNESS="$(packet004_importdomain_harness_root)"
STAMP="$(timestamp_utc)"
RUN_PARENT="$ARTIFACTS/runtime/packet004-importdomain"
RUN_DIR="${RUN_DIR:-$RUN_PARENT/$(safe_sw_build_slug)-$STAMP-$MODE}"
CONTROL_ROOT="$RUN_DIR/controlled"
DOMAIN_ID="packet004.$MODE.$STAMP"
DOMAIN_NAME="Packet004 ImportDomain $MODE $STAMP"
PREDICATE='process == "fileproviderd" OR process == "fileproviderctl" OR process == "Packet004ImportDomainHarness" OR process == "Packet004FileProviderExtension" OR eventMessage CONTAINS[c] "importDomain" OR eventMessage CONTAINS[c] "addDomain" OR eventMessage CONTAINS[c] "FileProvider" OR eventMessage CONTAINS[c] "sandbox extension" OR eventMessage CONTAINS[c] "realpath" OR eventMessage CONTAINS[c] "FPSandboxingURLWrapper" OR eventMessage CONTAINS[c] "fp_issueSandboxExtension" OR eventMessage CONTAINS[c] "packet004"'
CLEANUP_AFTER=1
if [[ "${PACKET004_KEEP_DOMAIN:-0}" == "1" ]]; then
  CLEANUP_AFTER=0
fi
PLUGIN_CLEANUP=1
if [[ "${PACKET004_KEEP_PLUGIN:-0}" == "1" ]]; then
  PLUGIN_CLEANUP=0
fi

require_cmd clang
require_cmd sw_vers
require_cmd /usr/bin/log
require_cmd /usr/bin/plutil
require_cmd /usr/bin/stat

mkdir -p "$RUN_DIR/environment" "$RUN_DIR/snapshots"

echo "[*] workspace: $WORKSPACE"
echo "[*] harness: $HARNESS"
echo "[*] run dir: $RUN_DIR"
echo "[*] mode: $MODE"

"$(applesauce_root)/tools/collect_campaign1_host_state.sh" "$RUN_DIR/environment/host-state" >/dev/null

"$HARNESS/scripts/build.sh" > "$RUN_DIR/build.txt" 2>&1

APP_LINE="$(awk -F= '$1=="app"{print $2}' "$RUN_DIR/build.txt" | tail -n 1)"
APP_EXE_LINE="$(awk -F= '$1=="app_executable"{print $2}' "$RUN_DIR/build.txt" | tail -n 1)"
EXT_LINE="$(awk -F= '$1=="extension"{print $2}' "$RUN_DIR/build.txt" | tail -n 1)"
EXT_ID_LINE="$(awk -F= '$1=="extension_id"{print $2}' "$RUN_DIR/build.txt" | tail -n 1)"
APP_BUNDLE="${APP_LINE:-$HARNESS/build/Packet004ImportDomainHarness.app}"
APP_EXE="${APP_EXE_LINE:-$APP_BUNDLE/Contents/MacOS/Packet004ImportDomainHarness}"
EXT_BUNDLE="${EXT_LINE:-$APP_BUNDLE/Contents/PlugIns/Packet004FileProviderExtension.appex}"
EXT_ID="${EXT_ID_LINE:-com.packet004.importdomain.harness.FileProvider}"

prepare_controlled_tree "$CONTROL_ROOT"
write_path_snapshot "import.before" "$IMPORT_URL" "$RUN_DIR/snapshots/import-url.before.txt"
if [[ -n "${SYMLINK_TARGET:-}" ]]; then
  write_path_snapshot "symlink-target.before" "$SYMLINK_TARGET" "$RUN_DIR/snapshots/symlink-target.before.txt"
fi
if [[ "$MODE" == "race" ]]; then
  write_path_snapshot "race-a.before" "$RACE_A" "$RUN_DIR/snapshots/race-a.before.txt"
  write_path_snapshot "race-b.before" "$RACE_B" "$RUN_DIR/snapshots/race-b.before.txt"
fi

{
  echo "mode=$MODE"
  echo "workspace=$WORKSPACE"
  echo "harness=$HARNESS"
  echo "app=$APP_BUNDLE"
  echo "app_executable=$APP_EXE"
  echo "extension=$EXT_BUNDLE"
  echo "extension_id=$EXT_ID"
  echo "import_url=$IMPORT_URL"
  echo "domain_id=$DOMAIN_ID"
  echo "domain_name=$DOMAIN_NAME"
  echo "cleanup_after=$CLEANUP_AFTER"
  echo "plugin_cleanup=$PLUGIN_CLEANUP"
  echo "predicate=$PREDICATE"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "ProductVersion=$(sw_vers -productVersion 2>/dev/null || true)"
  echo "BuildVersion=$(sw_vers -buildVersion 2>/dev/null || true)"
} > "$RUN_DIR/run-summary.txt"

{
  echo "=== bundle files ==="
  find "$APP_BUNDLE" -maxdepth 5 -print | sort
  echo
  echo "=== app info ==="
  /usr/bin/plutil -p "$APP_BUNDLE/Contents/Info.plist" || true
  echo
  echo "=== extension info ==="
  /usr/bin/plutil -p "$EXT_BUNDLE/Contents/Info.plist" || true
  echo
  echo "=== codesign app ==="
  codesign -dv --entitlements :- "$APP_BUNDLE" || true
  echo
  echo "=== codesign extension ==="
  codesign -dv --entitlements :- "$EXT_BUNDLE" || true
} > "$RUN_DIR/environment/bundle-state.txt" 2>&1

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  {
    echo "=== lsregister app ==="
    "$LSREGISTER" -f "$APP_BUNDLE" || true
    echo
    echo "=== lsregister extension ==="
    "$LSREGISTER" -f "$EXT_BUNDLE" || true
  } > "$RUN_DIR/environment/lsregister.txt" 2>&1
  echo "lsregister.available=1" > "$RUN_DIR/environment/lsregister-summary.txt"
else
  echo "lsregister.available=0" > "$RUN_DIR/environment/lsregister-summary.txt"
fi

if command -v pluginkit >/dev/null 2>&1; then
  {
    echo "=== pluginkit add ==="
    /usr/bin/pluginkit -a "$EXT_BUNDLE" || true
    echo
    echo "=== pluginkit match poll ==="
    for attempt in {1..20}; do
      echo "--- attempt $attempt ---"
      /usr/bin/pluginkit -m -A -D -v -i "$EXT_ID" || true
      if /usr/bin/pluginkit -m -A -D -v -i "$EXT_ID" 2>/dev/null | /usr/bin/grep -F "$EXT_ID" >/dev/null 2>&1; then
        echo "pluginkit.poll_match=present attempt=$attempt"
        break
      fi
      sleep "${PACKET004_PLUGIN_POLL_SLEEP:-0.5}"
    done
    echo
    echo "=== pluginkit protocol match ==="
    /usr/bin/pluginkit -m -A -D -v -p com.apple.fileprovider-nonui || true
  } > "$RUN_DIR/environment/pluginkit.txt" 2>&1
  if /usr/bin/grep -F "$EXT_ID" "$RUN_DIR/environment/pluginkit.txt" >/dev/null 2>&1; then
    echo "pluginkit.extension_match=present" > "$RUN_DIR/environment/registration-summary.txt"
  else
    echo "pluginkit.extension_match=missing" > "$RUN_DIR/environment/registration-summary.txt"
  fi
else
  echo "pluginkit.extension_match=unavailable" > "$RUN_DIR/environment/registration-summary.txt"
fi

if command -v fileproviderctl >/dev/null 2>&1; then
  {
    echo "=== fileproviderctl domains before ==="
    fileproviderctl domain list || true
  } > "$RUN_DIR/environment/fileproviderctl-before.txt" 2>&1
fi

write_manual_lldb "$RUN_DIR/manual-lldb-breakpoints.txt"
write_lldb_command_file "$RUN_DIR/lldb-commands.txt"

LOG_STREAM="$RUN_DIR/log-stream-fileprovider.txt"
/usr/bin/log stream --style syslog --level debug --predicate "$PREDICATE" > "$LOG_STREAM" 2>&1 &
LOG_PID=$!

cleanup() {
  stop_race_swapper
  if kill -0 "$LOG_PID" >/dev/null 2>&1; then
    kill "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

start_race_swapper
sleep "${PACKET004_IMPORTDOMAIN_PREFLIGHT_SLEEP:-1}"

APP_ARGS=(--mode "$MODE" --directory "$IMPORT_URL" --domain-id "$DOMAIN_ID" --domain-name "$DOMAIN_NAME" --timeout "${PACKET004_IMPORTDOMAIN_TIMEOUT:-60}")
if [[ "${PACKET004_REMOVE_DOMAIN_FIRST:-0}" == "1" ]]; then
  APP_ARGS+=(--remove-domain-first)
fi
if [[ "$CLEANUP_AFTER" == "1" ]]; then
  APP_ARGS+=(--remove-domain-after)
fi
if [[ "${PACKET004_SWIZZLE:-1}" == "0" ]]; then
  APP_ARGS+=(--no-swizzle)
fi
if [[ "${PACKET004_INSTRUMENT:-swizzle}" == "none" && "${PACKET004_SWIZZLE:-unset}" == "unset" ]]; then
  APP_ARGS+=(--no-swizzle)
fi

set +e
case "${PACKET004_INSTRUMENT:-swizzle}" in
  lldb)
    if [[ "${PACKET004_SWIZZLE:-unset}" == "unset" ]]; then
      APP_ARGS+=(--no-swizzle)
    fi
    if command -v lldb >/dev/null 2>&1; then
      lldb -b -s "$RUN_DIR/lldb-commands.txt" > "$RUN_DIR/app.stdout.txt" 2> "$RUN_DIR/app.stderr.txt"
      STATUS=$?
    elif command -v xcrun >/dev/null 2>&1; then
      xcrun lldb -b -s "$RUN_DIR/lldb-commands.txt" > "$RUN_DIR/app.stdout.txt" 2> "$RUN_DIR/app.stderr.txt"
      STATUS=$?
    else
      echo "lldb not found; see manual-lldb-breakpoints.txt" > "$RUN_DIR/app.stderr.txt"
      STATUS=2
    fi
    ;;
  swizzle|none|auto)
    "$APP_EXE" "${APP_ARGS[@]}" > "$RUN_DIR/app.stdout.txt" 2> "$RUN_DIR/app.stderr.txt"
    STATUS=$?
    ;;
  *)
    echo "unsupported PACKET004_INSTRUMENT=${PACKET004_INSTRUMENT}" > "$RUN_DIR/app.stderr.txt"
    STATUS=2
    ;;
esac
set -e

stop_race_swapper
sleep 2
cleanup
trap - EXIT

write_path_snapshot "import.after" "$IMPORT_URL" "$RUN_DIR/snapshots/import-url.after.txt"
if [[ -n "${SYMLINK_TARGET:-}" ]]; then
  write_path_snapshot "symlink-target.after" "$SYMLINK_TARGET" "$RUN_DIR/snapshots/symlink-target.after.txt"
fi
if [[ "$MODE" == "race" ]]; then
  write_path_snapshot "race-a.after" "$RACE_A" "$RUN_DIR/snapshots/race-a.after.txt"
  write_path_snapshot "race-b.after" "$RACE_B" "$RUN_DIR/snapshots/race-b.after.txt"
fi

/usr/bin/log show --style syslog --last "${LOG_SHOW_LAST:-8m}" --predicate "$PREDICATE" > "$RUN_DIR/log-show-fileprovider.txt" 2>&1 || true

if command -v fileproviderctl >/dev/null 2>&1; then
  {
    echo "=== fileproviderctl domains after ==="
    fileproviderctl domain list || true
  } > "$RUN_DIR/environment/fileproviderctl-after.txt" 2>&1
fi

if [[ "$PLUGIN_CLEANUP" == "1" ]] && command -v pluginkit >/dev/null 2>&1; then
  {
    echo "=== pluginkit remove ==="
    /usr/bin/pluginkit -r "$EXT_BUNDLE" || true
    echo
    echo "=== pluginkit match after remove ==="
    /usr/bin/pluginkit -m -A -D -v -i "$EXT_ID" || true
  } > "$RUN_DIR/environment/pluginkit-cleanup.txt" 2>&1
fi

search_hits "probe\\.install|probe\\.hit|probe\\.result|importDomain\\.|completion|fp_issueSandbox|FPSandboxingURLWrapper|wrapperWithURL|removeDomain|error" \
  "$RUN_DIR/caller-probe-hits.txt" "$RUN_DIR/app.stdout.txt" "$RUN_DIR/app.stderr.txt"

search_hits "importDomain|addDomain|sandbox extension|realpath|FPSandboxingURLWrapper|fp_issueSandbox|provider|domain|denied|deny|error|packet004" \
  "$RUN_DIR/daemon-log-hits.txt" "$RUN_DIR/log-stream-fileprovider.txt" "$RUN_DIR/log-show-fileprovider.txt"

{
  echo "run_dir=$RUN_DIR"
  echo "mode=$MODE"
  echo "status=$STATUS"
  echo "import_url=$IMPORT_URL"
  echo "domain_id=$DOMAIN_ID"
  echo
  echo "=== registration summary ==="
  sed -n '1,80p' "$RUN_DIR/environment/registration-summary.txt" || true
  sed -n '1,80p' "$RUN_DIR/environment/lsregister-summary.txt" || true
  echo
  echo "=== launchservices registration ==="
  sed -n '1,80p' "$RUN_DIR/environment/lsregister.txt" || true
  echo
  echo "=== pluginkit excerpt ==="
  sed -n '1,120p' "$RUN_DIR/environment/pluginkit.txt" || true
  echo
  echo "=== pluginkit cleanup ==="
  sed -n '1,120p' "$RUN_DIR/environment/pluginkit-cleanup.txt" || true
  echo
  echo "=== app stdout ==="
  sed -n '1,220p' "$RUN_DIR/app.stdout.txt" || true
  echo
  echo "=== app stderr ==="
  sed -n '1,120p' "$RUN_DIR/app.stderr.txt" || true
  echo
  echo "=== caller probe hits ==="
  echo "file=$RUN_DIR/caller-probe-hits.txt"
  echo "count=$(wc -l < "$RUN_DIR/caller-probe-hits.txt" | tr -d ' ')"
  sed -n '1,180p' "$RUN_DIR/caller-probe-hits.txt" || true
  echo
  echo "=== daemon log hits ==="
  echo "file=$RUN_DIR/daemon-log-hits.txt"
  echo "count=$(wc -l < "$RUN_DIR/daemon-log-hits.txt" | tr -d ' ')"
  sed -n '1,180p' "$RUN_DIR/daemon-log-hits.txt" || true
  echo
  echo "=== input snapshots ==="
  sed -n '1,120p' "$RUN_DIR/snapshots/import-url.before.txt" || true
  echo "--- after ---"
  sed -n '1,120p' "$RUN_DIR/snapshots/import-url.after.txt" || true
  echo
  echo "Decision rule:"
  echo "- treat probe.hit lines for wrapper/helper selectors in app.stdout.txt as caller-process reachability evidence."
  echo "- compare 26.4 and 26.5 runs for path canonicalization/rejection differences; one build alone is not a promotion signal."
  echo "- daemon acceptance/rejection and provider setup behavior alone are not enough for a vulnerability claim."
  echo "- park Packet 004 if importDomain is entitlement-gated, wrapper/helper is not reached, or both builds canonicalize/reject before issuance."
  echo
  echo "Manual LLDB fallback: $RUN_DIR/manual-lldb-breakpoints.txt"
  echo "RUN_DIR=$RUN_DIR"
} > "$RUN_DIR/importdomain-summary.txt" 2>&1

cat "$RUN_DIR/importdomain-summary.txt"
exit "$STATUS"
