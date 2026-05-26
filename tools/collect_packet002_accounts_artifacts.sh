#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  collect_packet002_accounts_artifacts.sh <label> [root]

examples:
  tools/collect_packet002_accounts_artifacts.sh 26.5 /
  tools/collect_packet002_accounts_artifacts.sh 26.4 /Volumes/Tahoe-26.4-Reacquire

Collects Packet 002 Accounts/privacy-preferences standalone and config
artifacts from a system root. This is binary/config intake only; it does not
run probes.
EOF
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage

LABEL="$1"
ROOT="${2:-/}"
ARTIFACTS="$(artifact_root)"
OUT="$ARTIFACTS/packet002-accounts-privacy/$LABEL"

if [[ ! -d "$ROOT" ]]; then
  echo "root not found: $ROOT" >&2
  exit 2
fi

ROOT="$(cd "$ROOT" && pwd)"
mkdir -p "$OUT"/{metadata,standalone,analysis/{entitlements,files,otool,plists,strings},profiles,feature-flags}

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
  # Accounts-owned daemon and support surface.
  "/System/Library/Frameworks/Accounts.framework/Versions/A/Support/accountsd"
  "/System/Library/Frameworks/Accounts.framework/Versions/A/Support/acdiagnose"
  "/System/Library/Frameworks/Accounts.framework/Versions/A/Resources/Info.plist"
  "/System/Library/Frameworks/Accounts.framework/Versions/A/Resources/version.plist"
  "/System/Library/Frameworks/Accounts.framework/Versions/A/Resources/Accounts_Private.apinotes"
  "/System/Library/LaunchAgents/com.apple.accountsd.plist"

  # AccountsDaemon service and account database model resources.
  "/System/Library/PrivateFrameworks/AccountsDaemon.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/AccountsDaemon.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/AccountsDaemon.framework/Versions/A/Resources/accounts.momd/VersionInfo.plist"
  "/System/Library/PrivateFrameworks/AccountsDaemon.framework/XPCServices/com.apple.accounts.dom.xpc/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/AccountsDaemon.framework/XPCServices/com.apple.accounts.dom.xpc/Contents/MacOS/com.apple.accounts.dom"
  "/System/Library/PrivateFrameworks/AccountsDaemon.framework/XPCServices/com.apple.accounts.dom.xpc/Contents/version.plist"

  # AppleAccount and account-role helpers.
  "/usr/libexec/appleaccountd"
  "/usr/libexec/xpcroleaccountd"
  "/System/Library/LaunchAgents/com.apple.appleaccountd.plist"
  "/System/Library/Sandbox/Profiles/com.apple.appleaccountd.sb"
  "/System/Library/Sandbox/Profiles/com.apple.xpc.xpcroleaccountd.sb"
  "/System/Library/PrivateFrameworks/AppleAccount.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/AppleAccount.framework/Versions/A/Resources/version.plist"

  # 26.5-added AppleAccountTransparency lane.
  "/System/Library/LaunchAgents/com.apple.appleaccounttransparencyd.plist"
  "/System/Library/Sandbox/Profiles/com.apple.appleaccounttransparencyd.sb"
  "/System/Library/PrivateFrameworks/AppleAccountTransparency.framework/Versions/A/Resources/appleaccounttransparencyd"
  "/System/Library/PrivateFrameworks/AppleAccountTransparency.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/AppleAccountTransparency.framework/Versions/A/Resources/version.plist"

  # Auth/account identity brokers.
  "/System/Library/PrivateFrameworks/AuthKit.framework/Versions/A/Support/akd"
  "/System/Library/LaunchAgents/com.apple.akd.plist"
  "/System/Library/LaunchDaemons/com.apple.akd.plist"
  "/System/Library/Sandbox/Profiles/com.apple.akd.sb"
  "/System/Library/PrivateFrameworks/AuthKit.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/AuthKit.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/AuthKit.framework/PlugIns/AKDiagnosticExtension.appex/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/AuthKit.framework/PlugIns/AKDiagnosticExtension.appex/Contents/MacOS/AKDiagnosticExtension"
  "/System/Library/PrivateFrameworks/AuthKit.framework/PlugIns/AKDiagnosticExtension.appex/Contents/version.plist"
  "/System/Library/PrivateFrameworks/AuthKitUI.framework/Versions/A/XPCServices/AKAuthorizationRemoteViewService.xpc/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/AuthKitUI.framework/Versions/A/XPCServices/AKAuthorizationRemoteViewService.xpc/Contents/MacOS/AKAuthorizationRemoteViewService"
  "/System/Library/PrivateFrameworks/AuthKitUI.framework/Versions/A/XPCServices/AKAuthorizationRemoteViewService.xpc/Contents/version.plist"

  # Internet/AOS/Commerce account surfaces visible in the release manifest.
  "/System/Library/CoreServices/UAUPlugins/InternetAccountsUAUPlugin.bundle/Contents/Info.plist"
  "/System/Library/CoreServices/UAUPlugins/InternetAccountsUAUPlugin.bundle/Contents/MacOS/InternetAccountsUAUPlugin"
  "/System/Library/CoreServices/UAUPlugins/iCloudAccountsMigratorPlugin.bundle/Contents/Info.plist"
  "/System/Library/CoreServices/UAUPlugins/iCloudAccountsMigratorPlugin.bundle/Contents/MacOS/iCloudAccountsMigratorPlugin"
  "/System/Library/PrivateFrameworks/AOSAccounts.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/AOSAccounts.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/AOSAccounts.framework/Versions/A/Resources/iCloudAccountsMigrator"
  "/System/Library/PrivateFrameworks/AOSAccounts.framework/Versions/A/Resources/iCloudUserNotificationsd.app/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/AOSAccounts.framework/Versions/A/Resources/iCloudUserNotificationsd.app/Contents/MacOS/iCloudUserNotificationsd"
  "/System/Library/PrivateFrameworks/CommerceKit.framework/Versions/A/Resources/storeaccountd"
  "/System/Library/LaunchAgents/com.apple.storeaccountd.plist"
  "/System/Library/Sandbox/Profiles/com.apple.storeaccountd.sb"
  "/System/Library/PrivateFrameworks/InternetAccounts.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/InternetAccounts.framework/Versions/A/Resources/Domains.plist"
  "/System/Library/PrivateFrameworks/InternetAccounts.framework/Versions/A/Resources/framework.sb"
  "/System/Library/PrivateFrameworks/InternetAccounts.framework/Versions/A/Resources/version.plist"

  # System Settings / App Intents account preference surfaces.
  "/System/Library/ExtensionKit/Extensions/AccountsUISettingsAppIntents.appex/Contents/Info.plist"
  "/System/Library/ExtensionKit/Extensions/AccountsUISettingsAppIntents.appex/Contents/MacOS/AccountsUISettingsAppIntents"
  "/System/Library/ExtensionKit/Extensions/AccountsUISettingsAppIntents.appex/Contents/Resources/Metadata.appintents/extract.actionsdata"
  "/System/Library/ExtensionKit/Extensions/AppleAccountIntents_macOS.appex/Contents/Info.plist"
  "/System/Library/ExtensionKit/Extensions/AppleAccountIntents_macOS.appex/Contents/MacOS/AppleAccountIntents_macOS"
  "/System/Library/ExtensionKit/Extensions/AppleAccountIntents_macOS.appex/Contents/Resources/Metadata.appintents/extract.actionsdata"
  "/System/Library/ExtensionKit/Extensions/InternetAccountsSettingsExtension.appex/Contents/Info.plist"
  "/System/Library/ExtensionKit/Extensions/InternetAccountsSettingsExtension.appex/Contents/MacOS/InternetAccountsSettingsExtension"
  "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/Info.plist"
  "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/MacOS/SecurityPrivacyExtension"
  "/System/Library/ExtensionKit/Extensions/SecurityPrivacyIntentsExtension.appex/Contents/Info.plist"
  "/System/Library/ExtensionKit/Extensions/SecurityPrivacyIntentsExtension.appex/Contents/MacOS/SecurityPrivacyIntentsExtension"
  "/System/Library/ExtensionKit/Extensions/SecurityPrivacyIntentsExtension.appex/Contents/Resources/Metadata.appintents/extract.actionsdata"

  # Permission/TCC privacy-adjacent context. Keep secondary unless Accounts callgraph ties in.
  "/System/Library/Frameworks/PermissionKit.framework/Versions/A/Resources/Info.plist"
  "/System/Library/Frameworks/PermissionKit.framework/Versions/A/Resources/version.plist"
  "/System/Library/Frameworks/_PermissionKit_AppKit.framework/Versions/A/Resources/Info.plist"
  "/System/Library/Frameworks/_PermissionKit_AppKit.framework/Versions/A/Resources/version.plist"
  "/System/Library/Frameworks/_PermissionKit_SwiftUI.framework/Versions/A/Resources/Info.plist"
  "/System/Library/Frameworks/_PermissionKit_SwiftUI.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/TCC.framework/Support/tccd"
  "/usr/bin/tccutil"
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/TCCMigration.bundle/Contents/MacOS/TCCMigration"
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/SystemTCCMigration.bundle/Contents/MacOS/SystemTCCMigration"
  "/System/Library/PrivateFrameworks/TCCInterface.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/TCCInterface.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/ConfigurationProfiles.framework/XPCServices/TCCProfileService.xpc/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/ConfigurationProfiles.framework/XPCServices/TCCProfileService.xpc/Contents/MacOS/TCCProfileService"
  "/usr/libexec/adprivacyd"
  "/usr/libexec/dprivacyd"

  # Feature flags that can explain apparent binary/config behavior.
  "/System/Library/FeatureFlags/Domain/AccountsUI.plist"
  "/System/Library/FeatureFlags/Domain/AppleAccount.plist"
  "/System/Library/FeatureFlags/Domain/AppleAccountUI.plist"
  "/System/Library/FeatureFlags/Domain/AuthKit.plist"
  "/System/Library/FeatureFlags/Domain/TCC.plist"
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
  nm -m "$src" > "$OUT/analysis/otool/$safe.nm-m.txt" 2>&1 || true
  codesign -d --entitlements - "$src" > "$OUT/analysis/entitlements/$safe.entitlements.xml" 2>"$OUT/analysis/entitlements/$safe.entitlements.stderr.txt" || true

  if [[ "$src" == *.plist ]]; then
    plutil -p "$src" > "$OUT/analysis/plists/$safe.plutil-p.txt" 2>&1 || true
  fi
}

for rel in "${FILES[@]}"; do
  copy_one "$rel"
done

for rel in \
  "/System/Library/Sandbox/Profiles/com.apple.appleaccountd.sb" \
  "/System/Library/Sandbox/Profiles/com.apple.appleaccounttransparencyd.sb" \
  "/System/Library/Sandbox/Profiles/com.apple.akd.sb" \
  "/System/Library/Sandbox/Profiles/com.apple.storeaccountd.sb" \
  "/System/Library/Sandbox/Profiles/com.apple.xpc.xpcroleaccountd.sb"; do
  src="$(root_join "$rel")"
  if [[ -f "$src" ]]; then
    dst="$OUT/profiles/${rel#"/System/Library/Sandbox/Profiles/"}"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
  fi
done

for rel in \
  "/System/Library/FeatureFlags/Domain/AccountsUI.plist" \
  "/System/Library/FeatureFlags/Domain/AppleAccount.plist" \
  "/System/Library/FeatureFlags/Domain/AppleAccountUI.plist" \
  "/System/Library/FeatureFlags/Domain/AuthKit.plist" \
  "/System/Library/FeatureFlags/Domain/TCC.plist"; do
  src="$(root_join "$rel")"
  if [[ -f "$src" ]]; then
    dst="$OUT/feature-flags/${rel#"/System/Library/FeatureFlags/Domain/"}"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    plutil -p "$src" > "$OUT/analysis/plists/$(safe_name "$rel").plutil-p.txt" 2>&1 || true
  fi
done

MANIFEST_DIFF="$(artifact_root)/release-manifests/diff-26.4-vs-26.5/changed-added-removed.tsv"
if [[ -f "$MANIFEST_DIFF" ]]; then
  grep -Ei 'Accounts|AppleAccount|AuthKit|InternetAccounts|accountsd|appleaccountd|xpcroleaccountd|PermissionKit|TCC|Privacy' "$MANIFEST_DIFF" > "$OUT/metadata/release-manifest-focus.tsv" 2>/dev/null || true
fi

find "$OUT/standalone" -type f -print > "$OUT/metadata/standalone-files.txt" 2>&1 || true
find "$OUT/profiles" -type f -print > "$OUT/metadata/profile-files.txt" 2>&1 || true
find "$OUT/feature-flags" -type f -print > "$OUT/metadata/feature-flag-files.txt" 2>&1 || true
write_sha256_manifest "$OUT/standalone" "$OUT/metadata/standalone-files.sha256"
write_sha256_manifest "$OUT/profiles" "$OUT/metadata/profile-files.sha256"
write_sha256_manifest "$OUT/feature-flags" "$OUT/metadata/feature-flag-files.sha256"

echo "$OUT"
