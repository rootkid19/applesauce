#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  collect_packet004_fileprovider_artifacts.sh <label> [root]

examples:
  tools/collect_packet004_fileprovider_artifacts.sh 26.5 /
  tools/collect_packet004_fileprovider_artifacts.sh 26.4 /Volumes/Tahoe-26.4

Collects Packet 004 FileProvider/materialization standalone artifacts from a
system root. The target list is Packet 004-specific; only the root/label are
portable across booted or mounted systems.
EOF
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage

LABEL="$1"
ROOT="${2:-/}"
ARTIFACTS="$(artifact_root)"
OUT="$ARTIFACTS/packet004-fileprovider/$LABEL"

if [[ ! -d "$ROOT" ]]; then
  echo "root not found: $ROOT" >&2
  exit 2
fi

ROOT="$(cd "$ROOT" && pwd)"
mkdir -p "$OUT"/{metadata,standalone,analysis/{entitlements,files,otool,plists,strings}}

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
  # Primary FileProvider surface.
  "/System/Library/Frameworks/FileProvider.framework/Support/fileproviderd"
  "/System/Library/Frameworks/FileProvider.framework/FileProvider"
  "/System/Library/Frameworks/FileProvider.framework/Versions/A/Resources/Info.plist"
  "/System/Library/Frameworks/FileProvider.framework/Versions/A/Resources/version.plist"
  "/System/Library/Frameworks/FileProvider.framework/Versions/A/Resources/NamespaceDescriptor.COREOS_FPFS_CONFIG.plist"
  "/System/Library/Frameworks/FileProvider.framework/Versions/A/Resources/NamespaceDescriptor.COREOS_FPFS_SPECULATIVE_DOWNLOADS.plist"
  "/System/Library/Frameworks/FileProvider.framework/Versions/A/Resources/default_factors_COREOS_FPFS_CONFIG.pb"
  "/System/Library/Frameworks/FileProvider.framework/Versions/A/Resources/default_factors_COREOS_FPFS_SPECULATIVE_DOWNLOADS.pb"
  "/System/Library/Frameworks/FileProvider.framework/OverrideBundles/iCloudDriveFileProviderOverride.bundle/Contents/Info.plist"
  "/System/Library/Frameworks/FileProvider.framework/OverrideBundles/FinderSyncCollaborationFileProviderOverride.bundle/Contents/Info.plist"
  "/System/Library/Frameworks/FileProvider.framework/OverrideBundles/FileProviderOverride.bundle/Contents/Info.plist"
  "/System/Library/Frameworks/FileProvider.framework/OverrideBundles/FileProviderOverride.bundle/Contents/Resources/FileProviderModule-Info.plist"
  "/System/Library/LaunchAgents/com.apple.FileProvider.plist"
  "/System/Library/FeatureFlags/Domain/FileProvider.plist"

  # Private FileProvider services.
  "/System/Library/PrivateFrameworks/FileProviderDaemon.framework/FileProviderDaemon"
  "/System/Library/PrivateFrameworks/FileProviderDaemon.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/FileProviderDaemon.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/FileProviderDaemon.framework/XPCServices/FPCKService.xpc/Contents/MacOS/FPCKService"
  "/System/Library/PrivateFrameworks/FileProviderDaemon.framework/XPCServices/FPCKService.xpc/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/FileProviderDaemon.framework/XPCServices/FPCKService.xpc/Contents/Resources/FPCKService.entitlements.in"
  "/System/Library/PrivateFrameworks/FileProviderDaemon.framework/XPCServices/FPCKService.xpc/Contents/Resources/AppStoreService.entitlements.in"
  "/System/Library/PrivateFrameworks/FileProviderDaemon.framework/XPCServices/AppStoreService.xpc/Contents/MacOS/AppStoreService"
  "/System/Library/PrivateFrameworks/FileProviderDaemon.framework/XPCServices/AppStoreService.xpc/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/FileProviderDaemon.framework/PlugIns/FileProviderDiagnosticExtension.appex/Contents/MacOS/FileProviderDiagnosticExtension"
  "/System/Library/PrivateFrameworks/FileProviderDaemon.framework/PlugIns/FileProviderDiagnosticExtension.appex/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/FileProviderResolver.framework/FileProviderResolver"
  "/System/Library/PrivateFrameworks/FileProviderResolver.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/FileProviderTelemetry.framework/FileProviderTelemetry"
  "/System/Library/PrivateFrameworks/FileProviderTelemetry.framework/Versions/A/Resources/Info.plist"
  "/System/Library/Frameworks/FileProviderUI.framework/FileProviderUI"
  "/System/Library/Frameworks/FileProviderUI.framework/Versions/A/Resources/Info.plist"

  # Promote only if changed by the diff.
  "/System/Library/PrivateFrameworks/CloudDocs.framework/CloudDocs"
  "/System/Library/PrivateFrameworks/CloudDocs.framework/PlugIns/com.apple.CloudDocs.iCloudDriveFileProvider.appex/Contents/MacOS/com.apple.CloudDocs.iCloudDriveFileProvider"
  "/System/Library/PrivateFrameworks/CloudDocs.framework/PlugIns/com.apple.CloudDocs.iCloudDriveFileProvider.appex/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/CloudDocs.framework/PlugIns/com.apple.CloudDocs.iCloudDriveFileProviderManaged.appex/Contents/MacOS/com.apple.CloudDocs.iCloudDriveFileProviderManaged"
  "/System/Library/PrivateFrameworks/CloudDocs.framework/PlugIns/com.apple.CloudDocs.iCloudDriveFileProviderManaged.appex/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/iCloudDriveCore.framework/iCloudDriveCore"
  "/System/Library/PrivateFrameworks/iCloudDriveCore.framework/Versions/A/Support/bird"
  "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/CloudKitDaemon"
  "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd"
  "/System/Library/LaunchAgents/com.apple.bird.plist"
  "/System/Library/LaunchAgents/com.apple.cloudd.plist"
  "/System/Library/LaunchDaemons/com.apple.cloudd.plist"

  # Storage sibling watchlist.
  "/System/Library/PrivateFrameworks/StorageManagement.framework/StorageManagement"
  "/System/Library/PrivateFrameworks/StorageManagement.framework/Versions/A/XPCServices/CloudStorageHelper.xpc/Contents/MacOS/CloudStorageHelper"
  "/System/Library/PrivateFrameworks/StorageManagement.framework/Versions/A/XPCServices/CloudStorageHelper.xpc/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/StorageManagement.framework/Versions/A/XPCServices/MessagesHelper.xpc/Contents/MacOS/MessagesHelper"
  "/System/Library/PrivateFrameworks/StorageManagement.framework/Versions/A/Resources/diskspaced"
  "/System/Library/PrivateFrameworks/StorageManagement.framework/PlugIns/StorageManagementService"
  "/System/Library/PrivateFrameworks/StorageManagementService.framework/StorageManagementService"
  "/System/Library/PrivateFrameworks/StorageKit.framework/StorageKit"
  "/System/Library/PrivateFrameworks/StorageUI.framework/StorageUI"
  "/System/Library/PrivateFrameworks/StorageContainersPrivate.framework/StorageContainersPrivate"
  "/System/Library/ExtensionKit/Extensions/Storage.appex/Contents/MacOS/Storage"
  "/System/Library/ExtensionKit/Extensions/Storage.appex/Contents/Info.plist"
  "/System/Library/ExtensionKit/Extensions/StorageDESSD.appex/Contents/MacOS/StorageDESSD"
  "/System/Library/ExtensionKit/Extensions/StorageDESDXC.appex/Contents/MacOS/StorageDESDXC"
  "/System/Library/ExtensionKit/Extensions/StorageSettingsIntentsExtension.appex/Contents/MacOS/StorageSettingsIntentsExtension"
  "/System/Library/LaunchDaemons/com.apple.storagekitd.plist"
  "/System/Library/LaunchAgents/com.apple.StorageManagement.Service.plist"
  "/System/Library/LaunchAgents/com.apple.StorageManagementUIHelper.plist"
  "/System/Library/FeatureFlags/Domain/StorageManagement.plist"
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

find "$OUT/standalone" -type f -print > "$OUT/metadata/standalone-files.txt" 2>&1 || true
write_sha256_manifest "$OUT/standalone" "$OUT/metadata/standalone-files.sha256"

echo "$OUT"
