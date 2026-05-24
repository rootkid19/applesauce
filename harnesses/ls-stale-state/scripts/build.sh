#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
SRC="$ROOT/src"

PARENT_APP="$BUILD/Parent.app"
HELPER_BG_APP="$BUILD/HelperBackground.app"
HELPER_FG_APP="$BUILD/HelperForeground.app"
INBUNDLE_HELPERS="$PARENT_APP/Contents/Helpers"

mkdir -p "$PARENT_APP/Contents/MacOS" "$PARENT_APP/Contents/Resources" "$INBUNDLE_HELPERS" "$HELPER_BG_APP/Contents/MacOS" "$HELPER_FG_APP/Contents/MacOS"

clang -fobjc-arc -framework Foundation -framework AppKit \
  "$SRC/ParentHarness.m" \
  -o "$PARENT_APP/Contents/MacOS/ParentHarness"

clang -fobjc-arc -framework Foundation -framework AppKit \
  "$SRC/HelperHarness.m" \
  -o "$HELPER_BG_APP/Contents/MacOS/HelperHarness"

clang -fobjc-arc -framework Foundation \
  "$SRC/HelperAgent.m" \
  -o "$PARENT_APP/Contents/MacOS/HelperAgent"

cp "$HELPER_BG_APP/Contents/MacOS/HelperHarness" "$HELPER_FG_APP/Contents/MacOS/HelperHarness"
cp "$HELPER_BG_APP/Contents/MacOS/HelperHarness" "$INBUNDLE_HELPERS/HelperHarness"

cat > "$PARENT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>ParentHarness</string>
  <key>CFBundleIdentifier</key>
  <string>com.chimera.lsstale.Parent</string>
  <key>CFBundleName</key>
  <string>LSStaleParent</string>
  <key>CFBundleDisplayName</key>
  <string>LSStaleParent</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.15</string>
</dict>
</plist>
PLIST

cat > "$HELPER_BG_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>HelperHarness</string>
  <key>CFBundleIdentifier</key>
  <string>com.chimera.lsstale.HelperBackground</string>
  <key>CFBundleName</key>
  <string>LSStaleHelperBackground</string>
  <key>CFBundleDisplayName</key>
  <string>LSStaleHelperBackground</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSBackgroundOnly</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>10.15</string>
</dict>
</plist>
PLIST

cat > "$HELPER_FG_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>HelperHarness</string>
  <key>CFBundleIdentifier</key>
  <string>com.chimera.lsstale.HelperForeground</string>
  <key>CFBundleName</key>
  <string>LSStaleHelperForeground</string>
  <key>CFBundleDisplayName</key>
  <string>LSStaleHelperForeground</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.15</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --sign - "$PARENT_APP" >/dev/null
/usr/bin/codesign --force --sign - "$HELPER_BG_APP" >/dev/null
/usr/bin/codesign --force --sign - "$HELPER_FG_APP" >/dev/null

echo "Built:"
echo "  $PARENT_APP"
echo "  $PARENT_APP/Contents/MacOS/HelperAgent"
echo "  $INBUNDLE_HELPERS/HelperHarness"
echo "  $HELPER_BG_APP"
echo "  $HELPER_FG_APP"
