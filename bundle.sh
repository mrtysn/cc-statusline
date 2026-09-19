#!/bin/bash
# DESC: Bundle Agent Bar Hopping into a macOS .app in ~/Applications
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Agent Bar Hopping"
BUNDLE_ID="local.agent-bar-hopping"
EXE_NAME="AgentBarHopping"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

# A stable signing identity, not ad-hoc, so the bundle keeps its identity across
# rebuilds. Falls back to ad-hoc where the cert is absent.
SIGN_ID="${CC_STATUSLINE_SIGN_ID:-Local Dev Signing}"
if ! security find-identity -v -p codesigning | grep -qF "$SIGN_ID"; then
    echo "note: signing identity '$SIGN_ID' not found — signing ad-hoc" >&2
    SIGN_ID="-"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$CONTENTS/Resources"

swiftc -O "$REPO/src/main.swift" -o "$MACOS/$EXE_NAME" -framework AppKit

# The app runs this checkout's cc-statusline.js rather than carrying a copy, so
# the window and the terminal always draw with the same renderer.
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${EXE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Agent Bar Hopping brings a session's iTerm tab to the front when you click its row.</string>
    <key>CCStatuslineRepo</key>
    <string>${REPO}</string>
</dict>
</plist>
PLIST

# assets/AppIcon.icns is committed, so the bundle's icon does not depend on what
# is installed on the machine. Regenerate it when the design changes:
#   make-icon cellularbars "#2f6f6a" assets/AppIcon.icns
cp "$REPO/assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP_DIR" >/dev/null

touch "$APP_DIR"

echo "Bundled to: $APP_DIR"
