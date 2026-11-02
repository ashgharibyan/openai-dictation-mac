#!/bin/zsh
# Copies build/Dictate.app to /Applications (quitting a running copy first) and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d build/Dictate.app ]] || ./scripts/build-app.sh

if pgrep -x Dictate >/dev/null; then
  echo "==> Quitting running Dictate"
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' build/Dictate.app/Contents/Info.plist)"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || pkill -x Dictate || true
  sleep 1
fi

echo "==> Installing to /Applications/Dictate.app"
rm -rf /Applications/Dictate.app
ditto build/Dictate.app /Applications/Dictate.app
open /Applications/Dictate.app
echo "==> Done. Look for the microphone icon in the menu bar."
