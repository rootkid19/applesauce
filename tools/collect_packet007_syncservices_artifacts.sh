#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  collect_packet007_syncservices_artifacts.sh <label> [root]

examples:
  tools/collect_packet007_syncservices_artifacts.sh 26.5 /
  tools/collect_packet007_syncservices_artifacts.sh 26.4 /Volumes/Tahoe-26.4

Collects Packet 007 Sync Services / Contacts-consent standalone and config
artifacts from a system root. This is binary/config intake only; it does not run
runtime probes.

Set APPLESAUCE_OVERWRITE=1 to replace a non-empty output directory.
EOF
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage

LABEL="$1"
ROOT="${2:-/}"
ARTIFACTS="$(artifact_root)"
OUT="$ARTIFACTS/packet007-syncservices-contacts/$LABEL"

if [[ ! -d "$ROOT" ]]; then
  echo "root not found: $ROOT" >&2
  exit 2
fi

if [[ -e "$OUT" && -n "$(find "$OUT" -mindepth 1 -print -quit 2>/dev/null || true)" ]]; then
  if [[ "${APPLESAUCE_OVERWRITE:-0}" != "1" ]]; then
    cat >&2 <<EOF
output already exists and is non-empty: $OUT

Use a fresh label, or rerun with:
  APPLESAUCE_OVERWRITE=1 $0 $LABEL $ROOT
EOF
    exit 2
  fi
  rm -rf "$OUT"
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
  # Primary advisory component: Sync Services.
  "/System/Library/Frameworks/SyncServices.framework/Versions/A/Resources/Info.plist"
  "/System/Library/Frameworks/SyncServices.framework/Versions/A/Resources/version.plist"
  "/System/Library/Frameworks/SyncServices.framework/Versions/A/Resources/dwsck"
  "/System/Library/Frameworks/SyncServices.framework/Versions/A/Resources/SyncServer.app/Contents/Info.plist"
  "/System/Library/Frameworks/SyncServices.framework/Versions/A/Resources/SyncServer.app/Contents/MacOS/SyncServer"
  "/System/Library/Frameworks/SyncServices.framework/Versions/A/Resources/SyncServer.app/Contents/Resources/Mingler"
  "/System/Library/Frameworks/SyncServices.framework/Versions/A/Resources/SyncServer.app/Contents/Resources/upgradedb"
  "/System/Library/LaunchAgents/com.apple.syncservices.SyncServer.plist"
  "/System/Library/LaunchAgents/com.apple.syncservices.uihandler.plist"

  # Contacts / AddressBook local data and sync support.
  "/System/Applications/Contacts.app/Contents/Info.plist"
  "/System/Applications/Contacts.app/Contents/MacOS/Contacts"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Resources/Info.plist"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Resources/version.plist"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Resources/AddressBook.syncschema"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Resources/SyncConfiguration.bundle/Contents/Info.plist"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Resources/AddressBookSourceSyncScheduleHelper"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Helpers/AddressBookManager.app/Contents/Info.plist"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Helpers/AddressBookManager.app/Contents/MacOS/AddressBookManager"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Helpers/ABAssistantService.app/Contents/Info.plist"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Helpers/ABAssistantService.app/Contents/MacOS/ABAssistantService"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Helpers/ABAssistantService.app/Contents/version.plist"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Helpers/ABAssistantService.app/Contents/Resources/com.apple.AddressBook.AssistantService.plist"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Helpers/AddressBookSourceSync.app/Contents/Info.plist"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/Helpers/AddressBookSourceSync.app/Contents/MacOS/AddressBookSourceSync"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/XPCServices/com.apple.AddressBook.ABPersonViewService.xpc/Contents/Info.plist"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/XPCServices/com.apple.AddressBook.ABPersonViewService.xpc/Contents/MacOS/com.apple.AddressBook.ABPersonViewService"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/XPCServices/com.apple.AddressBook.ABPersonViewService.xpc/Contents/version.plist"
  "/System/Library/Frameworks/AddressBook.framework/Helpers/AddressBookSync.app/Contents/Info.plist"
  "/System/Library/Frameworks/AddressBook.framework/Helpers/AddressBookSync.app/Contents/MacOS/AddressBookSync"
  "/System/Library/LaunchAgents/com.apple.AddressBook.AssistantService.plist"
  "/System/Library/LaunchAgents/com.apple.AddressBook.SourceSync.plist"
  "/System/Library/LaunchAgents/com.apple.AddressBook.abd.plist"

  # Contacts framework daemons and extensions.
  "/System/Library/Frameworks/Contacts.framework/Versions/A/Resources/Info.plist"
  "/System/Library/Frameworks/Contacts.framework/Versions/A/Resources/version.plist"
  "/System/Library/Frameworks/Contacts.framework/Versions/A/Resources/com.apple.contacts.plist"
  "/System/Library/Frameworks/Contacts.framework/Versions/A/Resources/CNContactMetadata.momd/VersionInfo.plist"
  "/System/Library/Frameworks/Contacts.framework/Support/contactsd"
  "/System/Library/Frameworks/Contacts.framework/Support/postersyncd"
  "/System/Library/Frameworks/Contacts.framework/PlugIns/ContactsCoreSpotlightExtension.appex/Contents/Info.plist"
  "/System/Library/Frameworks/Contacts.framework/PlugIns/ContactsCoreSpotlightExtension.appex/Contents/MacOS/ContactsCoreSpotlightExtension"
  "/System/Library/Frameworks/ContactsUI.framework/Versions/A/XPCServices/com.apple.ContactsUI.ContactPickerService.xpc/Contents/Info.plist"
  "/System/Library/Frameworks/ContactsUI.framework/Versions/A/XPCServices/com.apple.ContactsUI.ContactPickerService.xpc/Contents/MacOS/com.apple.ContactsUI.ContactPickerService"
  "/System/Library/LaunchAgents/com.apple.contactsd.plist"
  "/System/Library/LaunchAgents/com.apple.contacts.postersyncd.plist"
  "/System/Library/LaunchAgents/com.apple.contacts.donation-agent.plist"
  "/System/Library/Sandbox/Profiles/com.apple.contactsd.sb"
  "/System/Library/Sandbox/Profiles/com.apple.contacts.postersyncd.sb"
  "/System/Library/Sandbox/Profiles/contacts.sb"
  "/System/Library/Sandbox/Profiles/com.apple.iMessage.addressbook.sb"

  # Contacts account/dataclass plugins.
  "/System/Library/Accounts/Authentication/ContactsAccountsAuthenticationPlugin.bundle/Contents/Info.plist"
  "/System/Library/Accounts/Authentication/ContactsAccountsAuthenticationPlugin.bundle/Contents/MacOS/ContactsAccountsAuthenticationPlugin"
  "/System/Library/Accounts/DataclassOwners/ContactsAccountsDataclassOwnerPlugin.bundle/Contents/Info.plist"
  "/System/Library/Accounts/DataclassOwners/ContactsAccountsDataclassOwnerPlugin.bundle/Contents/MacOS/ContactsAccountsDataclassOwnerPlugin"
  "/System/Library/Accounts/Notification/ContactsAccountsNotificationPlugin.bundle/Contents/Info.plist"
  "/System/Library/Accounts/Notification/ContactsAccountsNotificationPlugin.bundle/Contents/MacOS/ContactsAccountsNotificationPlugin"
  "/System/Library/Accounts/UI/ContactsAccountsUIPlugin.bundle/Contents/Info.plist"
  "/System/Library/Accounts/UI/ContactsAccountsUIPlugin.bundle/Contents/MacOS/ContactsAccountsUIPlugin"
  "/System/Library/Accounts/SwiftUI/ContactsPlugin.bundle/Contents/Info.plist"
  "/System/Library/Accounts/SwiftUI/ContactsPlugin.bundle/Contents/MacOS/ContactsPlugin"
  "/System/Library/InternetAccounts/Migration/ContactsIAAccountMigratorPlugin.bundle/Contents/Info.plist"
  "/System/Library/InternetAccounts/Migration/ContactsIAAccountMigratorPlugin.bundle/Contents/MacOS/ContactsIAAccountMigratorPlugin"
  "/System/Library/Address Book Plug-Ins/CardDAVPlugin.sourcebundle/Contents/Info.plist"
  "/System/Library/Address Book Plug-Ins/CardDAVPlugin.sourcebundle/Contents/Resources/com.apple.contacts.carddav.plist"

  # DataAccess / Exchange sync lanes that often broker CardDAV/Contacts state.
  "/System/Library/PrivateFrameworks/DataAccess.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/DataAccess.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/DataAccess.framework/Support/dataaccessd"
  "/System/Library/PrivateFrameworks/ExchangeSync.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/ExchangeSync.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/ExchangeSync.framework/Versions/A/exchangesyncd"
  "/System/Library/LaunchAgents/com.apple.exchange.exchangesyncd.plist"

  # Adjacent sync daemons useful for ruling out broad "Sync Services" matches.
  "/System/Library/PrivateFrameworks/SyncedDefaults.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/SyncedDefaults.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/SyncedDefaults.framework/Support/syncdefaultsd"
  "/System/Library/LaunchAgents/com.apple.syncdefaultsd.plist"
  "/System/Library/Sandbox/Profiles/com.apple.syncdefaultsd.sb"
  "/System/Library/PrivateFrameworks/SyncServicesUI.framework/Versions/A/Resources/Conflict Resolver.app/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/SyncServicesUI.framework/Versions/A/Resources/Conflict Resolver.app/Contents/MacOS/Conflict Resolver"
  "/System/Library/PrivateFrameworks/SyncServicesUI.framework/Versions/A/Resources/Conflict Resolver.app/Contents/version.plist"
  "/System/Library/PrivateFrameworks/SyncServicesUI.framework/Versions/A/Resources/syncuid.app/Contents/Info.plist"
  "/System/Library/PrivateFrameworks/SyncServicesUI.framework/Versions/A/Resources/syncuid.app/Contents/MacOS/syncuid"
  "/System/Library/PrivateFrameworks/SyncServicesUI.framework/Versions/A/Resources/syncuid.app/Contents/version.plist"
  "/System/Library/PrivateFrameworks/EventKitExternalSync.framework/Versions/A/Resources/EventKitExternalSyncTool"
  "/System/Library/PrivateFrameworks/CallHistory.framework/Support/CallHistorySyncHelper"
  "/System/Library/LaunchAgents/com.apple.CallHistorySyncHelper.plist"
  "/System/Library/PrivateFrameworks/MapsSync.framework/mapssyncd"
  "/System/Library/LaunchAgents/com.apple.Maps.mapssyncd.plist"
  "/System/Library/Sandbox/Profiles/com.apple.Maps.mapssyncd.sb"

  # TCC / Contacts consent context.
  "/System/Library/PrivateFrameworks/TCC.framework/Support/tccd"
  "/usr/bin/tccutil"
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/version.plist"
  "/System/Library/PrivateFrameworks/TCCInterface.framework/Versions/A/Resources/Info.plist"
  "/System/Library/PrivateFrameworks/TCCInterface.framework/Versions/A/Resources/version.plist"

  # Feature flags that can explain config-only behavior.
  "/System/Library/FeatureFlags/Domain/Contacts.plist"
  "/System/Library/FeatureFlags/Domain/ExchangeSyncMac.plist"
  "/System/Library/FeatureFlags/Domain/GraphSync.plist"
  "/System/Library/FeatureFlags/Domain/SiriContacts.plist"
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
  "/System/Library/Sandbox/Profiles/com.apple.contactsd.sb" \
  "/System/Library/Sandbox/Profiles/com.apple.contacts.postersyncd.sb" \
  "/System/Library/Sandbox/Profiles/contacts.sb" \
  "/System/Library/Sandbox/Profiles/com.apple.iMessage.addressbook.sb" \
  "/System/Library/Sandbox/Profiles/com.apple.syncdefaultsd.sb" \
  "/System/Library/Sandbox/Profiles/com.apple.Maps.mapssyncd.sb"; do
  src="$(root_join "$rel")"
  if [[ -f "$src" ]]; then
    dst="$OUT/profiles/${rel#"/System/Library/Sandbox/Profiles/"}"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
  fi
done

for rel in \
  "/System/Library/FeatureFlags/Domain/Contacts.plist" \
  "/System/Library/FeatureFlags/Domain/ExchangeSyncMac.plist" \
  "/System/Library/FeatureFlags/Domain/GraphSync.plist" \
  "/System/Library/FeatureFlags/Domain/SiriContacts.plist" \
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
  grep -Ei 'SyncServices|Sync Services|Contacts|AddressBook|CardDAV|DataAccess|ExchangeSync|contactsd|TCC|Privacy' "$MANIFEST_DIFF" > "$OUT/metadata/release-manifest-focus.tsv" 2>/dev/null || true
fi

find "$OUT/standalone" -type f -print > "$OUT/metadata/standalone-files.txt" 2>&1 || true
find "$OUT/profiles" -type f -print > "$OUT/metadata/profile-files.txt" 2>&1 || true
find "$OUT/feature-flags" -type f -print > "$OUT/metadata/feature-flag-files.txt" 2>&1 || true
write_sha256_manifest "$OUT/standalone" "$OUT/metadata/standalone-files.sha256"
write_sha256_manifest "$OUT/profiles" "$OUT/metadata/profile-files.sha256"
write_sha256_manifest "$OUT/feature-flags" "$OUT/metadata/feature-flag-files.sha256"

echo "$OUT"
