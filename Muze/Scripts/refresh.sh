#!/bin/zsh
# Rebuild Muze, reinstall into /Applications, and relaunch it.
# Usage:  ./Scripts/refresh.sh
set -e
cd "$(dirname "$0")/.."

echo "→ building…"
./Scripts/make-app.sh          # swift build + assemble + sign + install to /Applications

echo "→ relaunching…"
pkill -f "Muze.app/Contents/MacOS/Muze" 2>/dev/null || true
sleep 1
open -a /Applications/Muze.app

# Nudge Finder/Dock so the icon isn't stale in the UI.
touch /Applications/Muze.app
echo "✓ Muze refreshed in /Applications and relaunched"
