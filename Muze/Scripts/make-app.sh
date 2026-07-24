#!/bin/zsh
# Build Muze.app from the SPM executable.
set -e
cd "$(dirname "$0")/.."

CONF="${1:-release}"
swift build -c "$CONF"

APP="build/Muze.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONF/Muze" "$APP/Contents/MacOS/Muze"
cp Resources/Muze.icns "$APP/Contents/Resources/Muze.icns"
[ -f Resources/home-bg-default.png ] && cp Resources/home-bg-default.png "$APP/Contents/Resources/home-bg-default.png"
[ -f Resources/recall.png ] && cp Resources/recall.png "$APP/Contents/Resources/recall.png"
[ -f Resources/recall-launch.jpg ] && cp Resources/recall-launch.jpg "$APP/Contents/Resources/recall-launch.jpg"
[ -f Resources/recall2.png ] && cp Resources/recall2.png "$APP/Contents/Resources/recall2.png"
[ -f Resources/recall-nobg.png ] && cp Resources/recall-nobg.png "$APP/Contents/Resources/recall-nobg.png"
if [ -d Resources/Fonts ]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
fi
if [ -d Resources/Characters ]; then
  mkdir -p "$APP/Contents/Resources/Characters"
  cp Resources/Characters/* "$APP/Contents/Resources/Characters/" 2>/dev/null || true
fi

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Muze</string>
  <key>CFBundleIdentifier</key><string>dev.shivam.recall</string>
  <key>CFBundleName</key><string>Muze</string>
  <key>CFBundleDisplayName</key><string>Muze</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>Muze</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Muze reads the active browser tab URL to give memories context.</string>
  <key>NSCameraUsageDescription</key>
  <string>With Eyes-on-screen enabled, Muze briefly checks the webcam when you go idle to tell whether you're still looking at the screen. Frames are analysed on-device and never stored or sent anywhere.</string>
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
  rm -rf "/Applications/Muze.app"
  cp -R "$APP" "/Applications/Muze.app"
  echo "✓ installed /Applications/Muze.app"
fi
