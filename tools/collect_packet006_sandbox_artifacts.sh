#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  collect_packet006_sandbox_artifacts.sh <label> [root]

examples:
  tools/collect_packet006_sandbox_artifacts.sh 26.5 /
  tools/collect_packet006_sandbox_artifacts.sh 26.4 /Volumes/Tahoe-26.4

Collects Packet 006 Sandbox/protected-data standalone and config artifacts from
a system root. This is binary/config intake only; it does not run probes.
EOF
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage

LABEL="$1"
ROOT="${2:-/}"
ARTIFACTS="$(artifact_root)"
OUT="$ARTIFACTS/packet006-sandbox-protected-data/$LABEL"

if [[ ! -d "$ROOT" ]]; then
  echo "root not found: $ROOT" >&2
  exit 2
fi

ROOT="$(cd "$ROOT" && pwd)"
mkdir -p "$OUT"/{metadata,standalone,analysis/{entitlements,files,otool,plists,strings},profiles,protected-cloud-storage-identities}

echo "[*] label: $LABEL"
echo "[*] root: $ROOT"
echo "[*] out: $OUT"

{
  echo "label=$LABEL"
  echo "root=$ROOT"
  date -u +"date_utc=%Y-%m-%dT%H:%M:%SZ"
  if [[ "$ROOT" == "/" ]]; then
    sw_vers 2>/dev/null || true
  elif [[ -f "$ROOT/System/Library/CoreServices/SystemVersion.plist" ]]; then
    plutil -p "$ROOT/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null || true
  fi
} > "$OUT/metadata/collection-context.txt" 2>&1

FILES=(
  # Primary Sandbox-owned standalone/config surface.
  "/usr/libexec/sandboxd"
  "/usr/bin/sandbox-exec"
  "/System/Library/LaunchDaemons/com.apple.sandboxd.plist"
  "/System/Library/PrivateFrameworks/AppSandbox.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/AppSandbox.framework/Versions/A/Resources/version.plist"

  # Adjacent protected-data attribution and scoped-bookmark context.
  "/System/Library/PrivateFrameworks/TCC.framework/Support/tccd"
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/TCCMigration.bundle/Contents/MacOS/TCCMigration"
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/TCCMigration.bundle/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/SystemTCCMigration.bundle/Contents/MacOS/SystemTCCMigration"
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/SystemTCCMigration.bundle/Contents/Info.plist"
  "/System/Library/LaunchAgents/com.apple.tccd.plist"
  "/System/Library/LaunchDaemons/com.apple.tccd.system.plist"
  "/System/Library/CoreServices/ScopedBookmarkAgent"
  "/System/Library/Preferences/Logging/Subsystems/com.apple.sandbox.plist"
  "/System/Library/Preferences/Logging/Subsystems/com.apple.TCC.plist"
  "/System/Library/FeatureFlags/Domain/TCC.plist"
  "/System/Library/FeatureFlags/Domain/ProtectedCloudStorage.plist"

  # Release-manifest-discovered Sandbox/TCC/container helper surfaces.
  "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/SandboxedServiceRunner.xpc/Contents/Info.plist"
  "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/SandboxedServiceRunner.xpc/Contents/MacOS/SandboxedServiceRunner"
  "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/SandboxedServiceRunner.xpc/Contents/version.plist"
  "/System/Library/Frameworks/AudioToolbox.framework/XPCServices/com.apple.audio.SandboxHelper.xpc/Contents/Info.plist"
  "/System/Library/Frameworks/AudioToolbox.framework/XPCServices/com.apple.audio.SandboxHelper.xpc/Contents/MacOS/com.apple.audio.SandboxHelper"
  "/System/Library/Frameworks/AudioToolbox.framework/XPCServices/com.apple.audio.SandboxHelper.xpc/Contents/version.plist"
  "/System/Library/Frameworks/Security.framework/Versions/A/XPCServices/XPCKeychainSandboxCheck.xpc/Contents/Info.plist"
  "/System/Library/Frameworks/Security.framework/Versions/A/XPCServices/XPCKeychainSandboxCheck.xpc/Contents/MacOS/XPCKeychainSandboxCheck"
  "/System/Library/Frameworks/Security.framework/Versions/A/XPCServices/XPCKeychainSandboxCheck.xpc/Contents/version.plist"
  "/System/Library/PrivateFrameworks/ConfigurationProfiles.framework/XPCServices/TCCProfileService.xpc/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/ConfigurationProfiles.framework/XPCServices/TCCProfileService.xpc/Contents/MacOS/TCCProfileService"
  "/System/Library/PrivateFrameworks/ConfigurationProfiles.framework/XPCServices/TCCProfileService.xpc/Contents/version.plist"
  "/System/Library/PrivateFrameworks/iCloudDriveService.framework/XPCServices/ContainerMetadataExtractor.xpc/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/iCloudDriveService.framework/XPCServices/ContainerMetadataExtractor.xpc/Contents/MacOS/ContainerMetadataExtractor"
  "/System/Library/PrivateFrameworks/iCloudDriveService.framework/XPCServices/ContainerMetadataExtractor.xpc/Contents/version.plist"
  "/System/Library/PrivateFrameworks/ProtectedCloudStorage.framework/Helpers/ProtectedCloudKeySyncing"
  "/System/Library/PrivateFrameworks/ProtectedCloudStorage.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/ProtectedCloudStorage.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/TCCInterface.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/TCCInterface.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/TCCSystemMigration.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/TCCSystemMigration.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/AppContainer.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/AppContainer.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/ContainerManagerCommon.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/ContainerManagerCommon.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/ContainerManagerSystem.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/ContainerManagerSystem.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/ContainerManagerUser.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/ContainerManagerUser.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/MobileContainerManager.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/MobileContainerManager.framework/Versions/A/Resources/version.plist"
  "/usr/libexec/ContainerMigrationService"
  "/usr/libexec/containermanagerd"
  "/usr/libexec/containermanagerd_system"
)

safe_name() {
  local rel="$1"
  rel="${rel#/}"
  echo "${rel//\//__}"
}

root_join() {
  local rel="$1"
  rel="${rel#/}"
  if [[ "$ROOT" == "/" ]]; then
    echo "/$rel"
  else
    echo "$ROOT/$rel"
  fi
}

copy_one() {
  local rel="$1"
  local src dst safe
  src="$(root_join "$rel")"
  safe="$(safe_name "$rel")"
  dst="$OUT/standalone/${rel#/}"

  {
    echo "path=$rel"
    echo "source=$src"
    if [[ -e "$src" || -L "$src" ]]; then
      ls -laeO@ "$src" || true
      file "$src" || true
      if [[ -L "$src" ]]; then
        echo "symlink_target=$(readlink "$src")"
      fi
    else
      echo "missing"
    fi
  } > "$OUT/analysis/files/$safe.file.txt" 2>&1

  if [[ ! -f "$src" ]]; then
    echo "$rel" >> "$OUT/metadata/missing-or-not-regular.txt"
    return 0
  fi

  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "$rel" >> "$OUT/metadata/copied.txt"

  shasum -a 256 "$src" > "$OUT/analysis/files/$safe.sha256" 2>&1 || true
  xattr -lr "$src" > "$OUT/analysis/files/$safe.xattr.txt" 2>&1 || true
  strings -a "$src" > "$OUT/analysis/strings/$safe.strings.txt" 2>&1 || true
  otool -L "$src" > "$OUT/analysis/otool/$safe.otool-L.txt" 2>&1 || true
  otool -Iv "$src" > "$OUT/analysis/otool/$safe.otool-Iv.txt" 2>&1 || true
  codesign -d --entitlements - "$src" > "$OUT/analysis/entitlements/$safe.entitlements.xml" 2>"$OUT/analysis/entitlements/$safe.entitlements.stderr.txt" || true

  if [[ "$src" == *.plist ]]; then
    plutil -p "$src" > "$OUT/analysis/plists/$safe.plutil-p.txt" 2>&1 || true
  fi
}

for rel in "${FILES[@]}"; do
  copy_one "$rel"
done

PROFILES_SRC="$(root_join "/System/Library/Sandbox/Profiles")"
if [[ -d "$PROFILES_SRC" ]]; then
  find "$PROFILES_SRC" -type f -name "*.sb" -print > "$OUT/metadata/sandbox-profiles-source.txt" 2>&1 || true
  while IFS= read -r profile; do
    rel="${profile#$ROOT/}"
    if [[ "$ROOT" == "/" ]]; then
      rel="${profile#/}"
    fi
    dst="$OUT/profiles/${rel#System/Library/Sandbox/Profiles/}"
    mkdir -p "$(dirname "$dst")"
    cp "$profile" "$dst"
  done < "$OUT/metadata/sandbox-profiles-source.txt"
else
  echo "missing profiles directory: $PROFILES_SRC" > "$OUT/metadata/sandbox-profiles-source.txt"
fi

PCS_SRC="$(root_join "/System/Library/Preferences/ProtectedCloudStorage/Identities")"
if [[ -d "$PCS_SRC" ]]; then
  find "$PCS_SRC" -type f -name "*.plist" -print > "$OUT/metadata/protected-cloud-storage-identities-source.txt" 2>&1 || true
  while IFS= read -r identity; do
    rel="${identity#$ROOT/}"
    if [[ "$ROOT" == "/" ]]; then
      rel="${identity#/}"
    fi
    dst="$OUT/protected-cloud-storage-identities/${rel#System/Library/Preferences/ProtectedCloudStorage/Identities/}"
    mkdir -p "$(dirname "$dst")"
    cp "$identity" "$dst"
  done < "$OUT/metadata/protected-cloud-storage-identities-source.txt"
else
  echo "missing identities directory: $PCS_SRC" > "$OUT/metadata/protected-cloud-storage-identities-source.txt"
fi

find "$OUT/standalone" -type f -print > "$OUT/metadata/standalone-files.txt" 2>&1 || true
find "$OUT/profiles" -type f -print > "$OUT/metadata/profile-files.txt" 2>&1 || true
find "$OUT/protected-cloud-storage-identities" -type f -print > "$OUT/metadata/protected-cloud-storage-identity-files.txt" 2>&1 || true
write_sha256_manifest "$OUT/standalone" "$OUT/metadata/standalone-files.sha256"
write_sha256_manifest "$OUT/profiles" "$OUT/metadata/profile-files.sha256"
write_sha256_manifest "$OUT/protected-cloud-storage-identities" "$OUT/metadata/protected-cloud-storage-identity-files.sha256"

echo "$OUT"
