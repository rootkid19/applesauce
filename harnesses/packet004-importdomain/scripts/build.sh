#!/bin/zsh
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$HARNESS_DIR/build"
APP_NAME="Packet004ImportDomainHarness"
EXT_NAME="Packet004FileProviderExtension"
APP_ID="${PACKET004_IMPORTDOMAIN_APP_ID:-com.packet004.importdomain.harness}"
EXT_ID="${PACKET004_IMPORTDOMAIN_EXTENSION_ID:-$APP_ID.FileProvider}"
GROUP_ID="${PACKET004_IMPORTDOMAIN_GROUP_ID:-group.com.packet004.importdomain}"

APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_EXE="$APP_CONTENTS/MacOS/$APP_NAME"
EXT_BUNDLE="$APP_CONTENTS/PlugIns/$EXT_NAME.appex"
EXT_CONTENTS="$EXT_BUNDLE/Contents"
EXT_EXE="$EXT_CONTENTS/MacOS/$EXT_NAME"

APP_SRC="$HARNESS_DIR/src/Packet004ImportDomainApp.m"
EXT_SRC="$HARNESS_DIR/src/Packet004FileProviderExtension.m"
APP_ENTITLEMENTS="$BUILD_DIR/app.entitlements.plist"
EXT_ENTITLEMENTS="$BUILD_DIR/extension.entitlements.plist"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/PlugIns" "$EXT_CONTENTS/MacOS" "$BUILD_DIR"

clang \
  -fobjc-arc \
  -fblocks \
  -O0 \
  -Wall \
  -Wextra \
  -framework Foundation \
  -framework FileProvider \
  "$APP_SRC" \
  -o "$APP_EXE"

clang \
  -fobjc-arc \
  -fblocks \
  -O0 \
  -Wall \
  -Wextra \
  -framework Foundation \
  -framework FileProvider \
  -framework UniformTypeIdentifiers \
  "$EXT_SRC" \
  -o "$EXT_EXE"

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

cat > "$EXT_CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$EXT_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$EXT_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$EXT_NAME</string>
  <key>CFBundlePackageType</key>
  <string>XPC!</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionFileProviderAppliesChangesAtomically</key>
    <true/>
    <key>NSExtensionFileProviderDocumentGroup</key>
    <string>$GROUP_ID</string>
    <key>NSExtensionFileProviderSupportsEnumeration</key>
    <true/>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.fileprovider-nonui</string>
    <key>NSExtensionPrincipalClass</key>
    <string>Packet004FileProviderExtension</string>
  </dict>
</dict>
</plist>
EOF

cat > "$APP_ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>$GROUP_ID</string>
  </array>
</dict>
</plist>
EOF

cat > "$EXT_ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>$GROUP_ID</string>
  </array>
</dict>
</plist>
EOF

/usr/bin/plutil -lint "$APP_CONTENTS/Info.plist" "$EXT_CONTENTS/Info.plist" "$APP_ENTITLEMENTS" "$EXT_ENTITLEMENTS" >/dev/null

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --entitlements "$EXT_ENTITLEMENTS" "$EXT_BUNDLE" >/dev/null
  codesign --force --sign - --entitlements "$APP_ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
else
  echo "warning: codesign not found; bundle left unsigned" >&2
fi

echo "app=$APP_BUNDLE"
echo "app_executable=$APP_EXE"
echo "extension=$EXT_BUNDLE"
echo "app_id=$APP_ID"
echo "extension_id=$EXT_ID"
echo "group_id=$GROUP_ID"
