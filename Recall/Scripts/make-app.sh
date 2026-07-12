#!/bin/zsh
# Build Recall.app from the SPM executable.
set -e
cd "$(dirname "$0")/.."

CONF="${1:-release}"
swift build -c "$CONF"

APP="build/Recall.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONF/Recall" "$APP/Contents/MacOS/Recall"
cp Resources/Recall.icns "$APP/Contents/Resources/Recall.icns"

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Recall</string>
  <key>CFBundleIdentifier</key><string>dev.shivam.recall</string>
  <key>CFBundleName</key><string>Recall</string>
  <key>CFBundleDisplayName</key><string>Recall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>Recall</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Recall reads the active browser tab URL to give memories context.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Sign with a stable identity so TCC permissions (Screen Recording /
# Accessibility) survive rebuilds. Falls back to ad-hoc if none found.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/ {print $2; exit}')
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "signed as: ${IDENTITY:-ad-hoc}"

echo "✓ built $APP"

# Install to /Applications (real app: Spotlight, Launchpad, login items).
if [ "${2:-install}" = "install" ]; then
  rm -rf "/Applications/Recall.app"
  cp -R "$APP" "/Applications/Recall.app"
  echo "✓ installed /Applications/Recall.app"
fi
