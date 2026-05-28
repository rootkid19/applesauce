#!/bin/zsh
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  collect_packet007_dyld_members.sh <label> <dyld_shared_cache_arm64e>

examples:
  APPLESAUCE_DYLD_LIGHT=1 tools/collect_packet007_dyld_members.sh 26.5 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
  APPLESAUCE_DYLD_LIGHT=1 tools/collect_packet007_dyld_members.sh 26.4 /path/to/26.4/dyld_shared_cache_arm64e

Extracts Packet 007 Sync Services / Contacts-consent dyld-cache members.
Prefers ipsw (brew install blacktop/tap/ipsw) for --objc --stubs enrichment.
Set APPLESAUCE_DYLD_LIGHT=1 to skip ipsw --objc/--stubs enrichment for faster
acquisition validation. The selected Mach-Os and local metadata are still
emitted.
Set APPLESAUCE_OVERWRITE=1 to replace a non-empty output directory.
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage

LABEL="$1"
CACHE="$2"
ARTIFACTS="$(artifact_root)"
OUT="$ARTIFACTS/dyld-members-packet007/$LABEL"
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$CACHE" ]]; then
  echo "cache not found: $CACHE" >&2
  exit 2
fi

if [[ -e "$OUT" && -n "$(find "$OUT" -mindepth 1 -print -quit 2>/dev/null || true)" ]]; then
  if [[ "${APPLESAUCE_OVERWRITE:-0}" != "1" ]]; then
    cat >&2 <<EOF
output already exists and is non-empty: $OUT

Use a fresh label, or rerun with:
  APPLESAUCE_OVERWRITE=1 $0 $LABEL $CACHE
EOF
    exit 2
  fi
  rm -rf "$OUT"
fi

mkdir -p "$OUT"/{members,selected,metadata}

echo "[*] label: $LABEL"
echo "[*] cache: $CACHE"
echo "[*] out: $OUT"

shasum -a 256 "$CACHE" > "$OUT/metadata/dyld_shared_cache_arm64e.sha256" 2>&1 || true
file "$CACHE" > "$OUT/metadata/dyld_shared_cache_arm64e.file.txt" 2>&1 || true
ls -laeO@ "$CACHE"* > "$OUT/metadata/cache-siblings-ls.txt" 2>&1 || true

MEMBERS=(
  # Primary advisory component and Contacts stack.
  "/System/Library/Frameworks/SyncServices.framework/Versions/A/SyncServices"
  "/System/Library/Frameworks/AddressBook.framework/Versions/A/AddressBook"
  "/System/Library/Frameworks/Contacts.framework/Versions/A/Contacts"
  "/System/Library/Frameworks/ContactsUI.framework/Versions/A/ContactsUI"
  "/System/Library/Frameworks/ContactProvider.framework/Versions/A/ContactProvider"

  # Private Contacts / AddressBook implementation.
  "/System/Library/PrivateFrameworks/AddressBookCore.framework/Versions/A/AddressBookCore"
  "/System/Library/PrivateFrameworks/AddressBookAutocomplete.framework/Versions/A/AddressBookAutocomplete"
  "/System/Library/PrivateFrameworks/ContactsAccounts.framework/Versions/A/ContactsAccounts"
  "/System/Library/PrivateFrameworks/ContactsAutocomplete.framework/Versions/A/ContactsAutocomplete"
  "/System/Library/PrivateFrameworks/ContactsAutocompleteUI.framework/Versions/A/ContactsAutocompleteUI"
  "/System/Library/PrivateFrameworks/ContactsDonation.framework/Versions/A/ContactsDonation"
  "/System/Library/PrivateFrameworks/ContactsDonationFeedback.framework/Versions/A/ContactsDonationFeedback"
  "/System/Library/PrivateFrameworks/ContactsFoundation.framework/Versions/A/ContactsFoundation"
  "/System/Library/PrivateFrameworks/ContactsMetrics.framework/Versions/A/ContactsMetrics"
  "/System/Library/PrivateFrameworks/ContactsPersistence.framework/Versions/A/ContactsPersistence"
  "/System/Library/PrivateFrameworks/ContactsPosterPersistence.framework/Versions/A/ContactsPosterPersistence"
  "/System/Library/PrivateFrameworks/ContactsUICore.framework/Versions/A/ContactsUICore"
  "/System/Library/PrivateFrameworks/ContactsUIMacHelper.framework/Versions/A/ContactsUIMacHelper"
  "/System/Library/PrivateFrameworks/ContactsAssistantServices.framework/Versions/A/ContactsAssistantServices"
  "/System/Library/PrivateFrameworks/ManagedOrganizationContacts.framework/Versions/A/ManagedOrganizationContacts"

  # Sync engines and CardDAV / Exchange / DataAccess lanes.
  "/System/Library/PrivateFrameworks/DataAccess.framework/Versions/A/DataAccess"
  "/System/Library/PrivateFrameworks/DataAccessExpress.framework/Versions/A/DataAccessExpress"
  "/System/Library/PrivateFrameworks/CDDataAccess.framework/Versions/A/CDDataAccess"
  "/System/Library/PrivateFrameworks/CDDataAccessExpress.framework/Versions/A/CDDataAccessExpress"
  "/System/Library/PrivateFrameworks/ExchangeSync.framework/Versions/A/ExchangeSync"
  "/System/Library/PrivateFrameworks/ExchangeSyncExpress.framework/Versions/A/ExchangeSyncExpress"
  "/System/Library/PrivateFrameworks/EventKitExternalSync.framework/Versions/A/EventKitExternalSync"
  "/System/Library/PrivateFrameworks/CloudKitDistributedSync.framework/Versions/A/CloudKitDistributedSync"
  "/System/Library/PrivateFrameworks/SyncServicesUI.framework/Versions/A/SyncServicesUI"

  # Adjacent sync context for ruling out broad "Sync Services" hits.
  "/System/Library/PrivateFrameworks/SyncedDefaults.framework/Versions/A/SyncedDefaults"
  "/System/Library/PrivateFrameworks/SyncedDefaultsDaemon.framework/Versions/A/SyncedDefaultsDaemon"
  "/System/Library/PrivateFrameworks/ContextSync.framework/Versions/A/ContextSync"
  "/System/Library/PrivateFrameworks/CoreDuetSync.framework/Versions/A/CoreDuetSync"
  "/System/Library/PrivateFrameworks/MapsSync.framework/Versions/A/MapsSync"
  "/System/Library/PrivateFrameworks/BiomeSync.framework/Versions/A/BiomeSync"

  # Privacy/consent and account dataclass context.
  "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
  "/System/Library/PrivateFrameworks/TCCInterface.framework/Versions/A/TCCInterface"
  "/System/Library/Frameworks/Accounts.framework/Versions/A/Accounts"
  "/System/Library/PrivateFrameworks/AccountsDaemon.framework/Versions/A/AccountsDaemon"
  "/System/Library/PrivateFrameworks/InternetAccounts.framework/Versions/A/InternetAccounts"
)

printf '%s\n' "${MEMBERS[@]}" > "$OUT/metadata/requested-members.txt"

extractor=""
if command -v ipsw >/dev/null 2>&1; then
  extractor="ipsw"
elif command -v dyld_shared_cache_util >/dev/null 2>&1; then
  extractor="dyld_shared_cache_util"
elif command -v dsc_extractor >/dev/null 2>&1; then
  extractor="dsc_extractor"
elif [[ -x "$TOOLS_DIR/dsc_extract_bundle" || -f /usr/lib/dsc_extractor.bundle ]]; then
  if [[ ! -x "$TOOLS_DIR/dsc_extract_bundle" ]]; then
    "$TOOLS_DIR/build_dsc_extractor_bundle_wrapper.sh" > "$OUT/metadata/build-dsc-wrapper.stdout.txt" 2>"$OUT/metadata/build-dsc-wrapper.stderr.txt"
  fi
  extractor="dsc_extract_bundle"
fi

if [[ -z "$extractor" ]]; then
  cat > "$OUT/metadata/extraction-blocked.txt" <<'EOF'
No supported extractor found in PATH.

Preferred:
  brew install blacktop/tap/ipsw

Or install/build one of:
- dyld_shared_cache_util
- dsc_extractor
- /usr/lib/dsc_extractor.bundle wrapper via tools/build_dsc_extractor_bundle_wrapper.sh
EOF
  cat "$OUT/metadata/extraction-blocked.txt"
  exit 1
fi

{
  echo "extractor=$extractor"
  if [[ "$extractor" == "ipsw" ]]; then
    ipsw version 2>/dev/null || echo "version=unknown"
    if [[ "${APPLESAUCE_DYLD_LIGHT:-0}" == "1" ]]; then
      echo "ipsw_enrichment=light"
    else
      echo "ipsw_enrichment=objc-stubs"
    fi
  else
    echo "version=n/a"
  fi
  echo "cache=$CACHE"
} > "$OUT/metadata/extractor.txt"

print_member_list() {
  case "$extractor" in
    ipsw)
      ipsw dyld info --dylibs --no-color "$CACHE" 2>/dev/null
      ;;
    dyld_shared_cache_util)
      dyld_shared_cache_util -list "$CACHE"
      ;;
    dsc_extractor)
      dsc_extractor --list "$CACHE"
      ;;
    dsc_extract_bundle)
      echo "local dsc_extract_bundle fallback does not support listing"
      ;;
  esac
}

extract_member() {
  local member="$1"
  local rel="${member#/}"
  local safe="${rel//\//__}"
  local stdout="$OUT/metadata/$safe.extract.stdout.txt"
  local stderr="$OUT/metadata/$safe.extract.stderr.txt"
  case "$extractor" in
    ipsw)
      if [[ "${APPLESAUCE_DYLD_LIGHT:-0}" == "1" ]]; then
        ipsw dyld extract --force --no-color -o "$OUT/members" "$CACHE" "$member" >"$stdout" 2>"$stderr"
      else
        ipsw dyld extract --objc --stubs --force --no-color -o "$OUT/members" "$CACHE" "$member" >"$stdout" 2>"$stderr"
      fi
      ;;
    dyld_shared_cache_util)
      dyld_shared_cache_util -extract "$member" "$CACHE" "$OUT/members" >"$stdout" 2>"$stderr"
      ;;
    dsc_extractor)
      dsc_extractor --extract "$member" "$CACHE" "$OUT/members" >"$stdout" 2>"$stderr"
      ;;
    dsc_extract_bundle)
      return 3
      ;;
  esac
}

print_member_list > "$OUT/metadata/cache-members.txt" 2>"$OUT/metadata/cache-members.stderr.txt" || true

copy_selected_member() {
  local base="$1"
  local member="$2"
  local rel="${member#/}"
  local src="$base/$rel"
  local dst="$OUT/selected/$rel"
  local safe="${rel//\//__}"

  if [[ ! -f "$src" ]]; then
    src="$(find "$base" -type f -path "*/$rel" -print -quit 2>/dev/null || true)"
  fi

  if [[ -z "$src" || ! -f "$src" ]]; then
    src="$base/$(basename "$member")"
  fi

  if [[ -z "$src" || ! -f "$src" ]]; then
    echo "$member" >> "$OUT/metadata/selected-missing.txt"
    return 1
  fi

  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  file "$dst" > "$OUT/metadata/$safe.file.txt" 2>&1 || true
  shasum -a 256 "$dst" > "$OUT/metadata/$safe.sha256" 2>&1 || true
  strings -a "$dst" > "$OUT/metadata/$safe.strings.txt" 2>&1 || true
  nm -m "$dst" > "$OUT/metadata/$safe.nm-m.txt" 2>&1 || true
  otool -L "$dst" > "$OUT/metadata/$safe.otool-L.txt" 2>&1 || true
  otool -Iv "$dst" > "$OUT/metadata/$safe.otool-Iv.txt" 2>&1 || true
  echo "$member" >> "$OUT/metadata/selected.txt"
}

if [[ "$extractor" == "dsc_extract_bundle" ]]; then
  FULL="$OUT/full-extract"
  mkdir -p "$FULL"
  echo "[*] extractor: local dsc_extract_bundle full-cache fallback"
  "$TOOLS_DIR/dsc_extract_bundle" "$CACHE" "$FULL" > "$OUT/metadata/full-extract.stdout.txt" 2>"$OUT/metadata/full-extract.stderr.txt"

  for member in "${MEMBERS[@]}"; do
    echo "[*] selecting $member"
    copy_selected_member "$FULL" "$member" || true
  done

  if [[ "${APPLESAUCE_KEEP_FULL_EXTRACT:-0}" != "1" ]]; then
    echo "[*] removing temporary full-extract output"
    rm -rf "$FULL"
    echo "removed; set APPLESAUCE_KEEP_FULL_EXTRACT=1 to keep it" > "$OUT/metadata/full-extract.removed.txt"
  fi
else
  echo "[*] extractor: $extractor"
  for member in "${MEMBERS[@]}"; do
    echo "[*] extracting $member"
    if extract_member "$member"; then
      echo "$member" >> "$OUT/metadata/extracted.txt"
      copy_selected_member "$OUT/members" "$member" || true
    else
      echo "$member" >> "$OUT/metadata/missing-or-failed.txt"
    fi
  done
fi

find "$OUT/members" -type f -print > "$OUT/metadata/extracted-files.txt" 2>&1 || true
find "$OUT/selected" -type f -print > "$OUT/metadata/selected-files.txt" 2>&1 || true
write_sha256_manifest "$OUT/members" "$OUT/metadata/extracted-files.sha256"
write_sha256_manifest "$OUT/selected" "$OUT/metadata/selected-files.sha256"

echo "$OUT"
