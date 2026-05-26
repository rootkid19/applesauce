#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  reverse_authority_map.sh <mach-o-or-bundle> <output-dir>

examples:
  tools/reverse_authority_map.sh /path/to/akd /tmp/akd-authority
  tools/reverse_authority_map.sh /System/Library/PrivateFrameworks/AuthKit.framework /tmp/authkit-authority
  tools/reverse_authority_map.sh artifacts/packet002-accounts-privacy/26.5/standalone/System/Library/PrivateFrameworks/AuthKit.framework/Versions/A/Support/akd /tmp/akd-authority

Builds a deterministic authority surface map for a Mach-O binary or bundle:
  identity.txt          - file type, sha256
  imports.txt           - otool -L dylib imports
  symbols-nm.txt        - nm -m symbol table
  strings-authority.txt - strings filtered for authority-relevant patterns
  objc-metadata.txt     - otool -ov ObjC section dump
  swift-demangled.txt   - demangled Swift symbols (if present)
  bundle-info-plist.txt - Info.plist contents (bundles only)
  sandbox-profile-refs.txt  - .sb paths found in strings
  launchd-refs.txt          - launchd/plist paths found in strings

If a command is unavailable or the file is not Mach-O, the failure is
recorded and the script continues.
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage

INPUT="$1"
OUTDIR="$2"

if [[ ! -e "$INPUT" ]]; then
  echo "not found: $INPUT" >&2
  exit 2
fi

mkdir -p "$OUTDIR"

# Resolve the primary Mach-O target from a bundle or a plain file.
TARGET=""
BUNDLE_ROOT=""

if [[ -d "$INPUT" ]]; then
  BUNDLE_ROOT="$INPUT"
  local_name="$(basename "$INPUT")"
  local_name="${local_name%.framework}"
  local_name="${local_name%.appex}"
  local_name="${local_name%.app}"
  local_name="${local_name%.xpc}"
  local_name="${local_name%.bundle}"
  for candidate in \
    "$INPUT/Contents/MacOS/$local_name" \
    "$INPUT/Versions/A/$local_name" \
    "$INPUT/Versions/Current/$local_name" \
    "$INPUT/$local_name"; do
    if [[ -f "$candidate" ]]; then
      TARGET="$candidate"
      break
    fi
  done
  if [[ -z "$TARGET" ]]; then
    TARGET="$(find "$INPUT" -maxdepth 5 -type f -name "$local_name" -print -quit 2>/dev/null || true)"
  fi
elif [[ -f "$INPUT" ]]; then
  TARGET="$INPUT"
fi

if [[ -z "$TARGET" || ! -f "$TARGET" ]]; then
  printf 'could not locate Mach-O in: %s\n' "$INPUT" | tee "$OUTDIR/error.txt" >&2
  exit 2
fi

echo "[*] input:  $INPUT"
echo "[*] target: $TARGET"
echo "[*] out:    $OUTDIR"

# --- identity ---
{
  printf 'input=%s\n' "$INPUT"
  printf 'target=%s\n' "$TARGET"
  date -u +"date_utc=%Y-%m-%dT%H:%M:%SZ"
  file "$TARGET" 2>&1 || printf 'file: unavailable\n'
  shasum -a 256 "$TARGET" 2>&1 || printf 'sha256: unavailable\n'
} > "$OUTDIR/identity.txt" 2>&1

# --- imports ---
{
  otool -L "$TARGET" 2>&1 || printf 'otool -L: unavailable or not Mach-O\n'
} > "$OUTDIR/imports.txt"

# --- symbol table ---
if command -v nm >/dev/null 2>&1; then
  nm -m "$TARGET" > "$OUTDIR/symbols-nm.txt" 2>&1 || printf 'nm failed\n' > "$OUTDIR/symbols-nm.txt"
else
  printf 'nm: unavailable\n' > "$OUTDIR/symbols-nm.txt"
fi

# --- authority-relevant strings ---
# Covers: audit token, PID validation, SecTask/SecCode, XPC, entitlement keys,
# TCC/privacy, sandbox extension, path canonicalization, security-scoped bookmark.
AUTHORITY_PAT='audit_token|xpc_connection_get_audit_token|AuditToken|proc_pidpath|getpid\b|SecTaskCreate|SecTaskCopyValueForEntitlement|SecCodeCreate|SecStaticCode|SecRequirementCreate|SecCopyEntitlement|xpc_connection|NSXPCConnection|NSXPCListener|NSXPCInterface|exportedInterface|remoteObjectInterface|machServiceName|bootstrap_look_up|mach_port_|task_for_pid|taskForPid|com\.apple\.private\.|com\.apple\.security\.|com\.apple\.developer\.|kTCCService|TCCAccess|NSAppleEventsUsage|NSCamera|NSMicrophone|NSLocation|NSContacts|com\.apple\.private\.tcc|sandbox_extension_issue|sandbox_extension_consume|sandbox_extension_apply|sandbox_extension_release|SANDBOX_EXTENSION|_sandbox_extension|realpath\b|lstat\b|canonicalize|normalize_path|symlink\b|SecBookmark|kSecBookmark|NSURLBookmarkData|startAccessingSecurityScopedResource|stopAccessingSecurityScopedResource|security[-.]scoped|NSURLBookmark'

if command -v strings >/dev/null 2>&1; then
  strings -a "$TARGET" 2>/dev/null \
    | grep -E "$AUTHORITY_PAT" \
    > "$OUTDIR/strings-authority.txt" 2>/dev/null || true
  if [[ ! -s "$OUTDIR/strings-authority.txt" ]]; then
    printf 'no authority-relevant strings found\n' > "$OUTDIR/strings-authority.txt"
  fi
else
  printf 'strings: unavailable\n' > "$OUTDIR/strings-authority.txt"
fi

# --- ObjC section metadata ---
{
  otool -ov "$TARGET" 2>&1 || printf 'otool -ov: unavailable or no ObjC section\n'
} > "$OUTDIR/objc-metadata.txt"

# --- Swift demangled symbols ---
typeset -a SWIFT_DEMANGLE_CMD
SWIFT_DEMANGLE_CMD=()
if command -v swift-demangle >/dev/null 2>&1; then
  SWIFT_DEMANGLE_CMD=(swift-demangle)
elif command -v xcrun >/dev/null 2>&1 && xcrun --find swift-demangle >/dev/null 2>&1; then
  SWIFT_DEMANGLE_CMD=(xcrun swift-demangle)
fi

if [[ ${#SWIFT_DEMANGLE_CMD[@]} -gt 0 ]] && command -v nm >/dev/null 2>&1; then
  nm -m "$TARGET" 2>/dev/null \
    | grep -E ' \$s[A-Za-z0-9_]+' \
    | awk '{print $NF}' \
    | "${SWIFT_DEMANGLE_CMD[@]}" \
    > "$OUTDIR/swift-demangled.txt" 2>&1 || true
  if [[ ! -s "$OUTDIR/swift-demangled.txt" ]]; then
    printf 'no Swift symbols found\n' > "$OUTDIR/swift-demangled.txt"
  fi
else
  printf 'swift-demangle or nm: unavailable\n' > "$OUTDIR/swift-demangled.txt"
fi

# --- bundle metadata ---
if [[ -n "$BUNDLE_ROOT" ]]; then
  for plist_candidate in \
    "$BUNDLE_ROOT/Contents/Info.plist" \
    "$BUNDLE_ROOT/Resources/Info.plist" \
    "$BUNDLE_ROOT/Versions/A/Resources/Info.plist"; do
    if [[ -f "$plist_candidate" ]]; then
      plutil -p "$plist_candidate" > "$OUTDIR/bundle-info-plist.txt" 2>&1 \
        || cp "$plist_candidate" "$OUTDIR/bundle-info-plist.txt" 2>/dev/null || true
      break
    fi
  done
fi

# --- sandbox profile and launchd plist references from strings ---
grep -E '\.sb"?$|\.sb"?\s' "$OUTDIR/strings-authority.txt" \
  > "$OUTDIR/sandbox-profile-refs.txt" 2>/dev/null || true
[[ -s "$OUTDIR/sandbox-profile-refs.txt" ]] || printf 'none found\n' > "$OUTDIR/sandbox-profile-refs.txt"

grep -E 'com\.apple\.[a-zA-Z0-9._-]+\.plist|LaunchAgents|LaunchDaemons|launchd\.plist' \
  "$OUTDIR/strings-authority.txt" \
  > "$OUTDIR/launchd-refs.txt" 2>/dev/null || true
[[ -s "$OUTDIR/launchd-refs.txt" ]] || printf 'none found\n' > "$OUTDIR/launchd-refs.txt"

echo "[done] $OUTDIR"
