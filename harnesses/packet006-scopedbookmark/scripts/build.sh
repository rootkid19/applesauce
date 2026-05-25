#!/bin/zsh
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$HARNESS_DIR/build"
APP_NAME="Packet006ScopedBookmarkHarness"
APP_ID="${PACKET006_SCOPEDBOOKMARK_APP_ID:-com.packet006.scopedbookmark.harness}"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_EXE="$APP_CONTENTS/MacOS/$APP_NAME"
APP_SRC="$HARNESS_DIR/src/Packet006ScopedBookmarkApp.m"
APP_ENTITLEMENTS="$BUILD_DIR/app.entitlements.plist"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_CONTENTS/MacOS" "$BUILD_DIR"

clang \
  -fobjc-arc \
  -fblocks \
  -O0 \
  -g \
  -Wall \
  -Wextra \
  -framework Foundation \
  "$APP_SRC" \
  -o "$APP_EXE"

cat > "$APP_CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$APP_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
</dict>
</plist>
EOF

PROFILE="${PACKET006_SCOPEDBOOKMARK_ENTITLEMENT_PROFILE:-}"
if [[ -z "$PROFILE" ]]; then
  if [[ "${PACKET006_SCOPEDBOOKMARK_ENTITLEMENTS:-1}" == "1" ]]; then
    PROFILE="full"
  else
    PROFILE="none"
  fi
fi

case "$PROFILE" in
  full)
  cat > "$APP_ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.files.user-selected.read-write</key>
  <true/>
  <key>com.apple.security.files.bookmarks.app-scope</key>
  <true/>
</dict>
</plist>
EOF
    ;;
  sandbox-only)
  cat > "$APP_ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
</dict>
</plist>
EOF
    ;;
  none)
  cat > "$APP_ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
EOF
    ;;
  *)
    echo "unknown PACKET006_SCOPEDBOOKMARK_ENTITLEMENT_PROFILE: $PROFILE" >&2
    exit 2
    ;;
esac

/usr/bin/plutil -lint "$APP_CONTENTS/Info.plist" "$APP_ENTITLEMENTS" >/dev/null

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --entitlements "$APP_ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
  codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null
else
  echo "warning: codesign not found; bundle left unsigned" >&2
fi

echo "app=$APP_BUNDLE"
echo "app_executable=$APP_EXE"
echo "app_id=$APP_ID"
echo "entitlements=$APP_ENTITLEMENTS"
echo "entitlement_profile=$PROFILE"
