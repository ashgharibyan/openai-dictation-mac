#!/bin/zsh
# Builds build/Dictate.app (release, arm64) and signs it.
#   ./scripts/build-app.sh            # sign with "Dictate Local Signing" if present, else ad hoc
#   SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Dictate.app"
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Dictate Local Signing"; then
  IDENTITY="Dictate Local Signing"
fi

echo "==> Running core tests"
swift run -c release DictateCoreTests

echo "==> Building release binary"
swift build -c release --product Dictate
BIN="$(swift build -c release --show-bin-path)/Dictate"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Dictate"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
[[ -f Packaging/AppIcon.icns ]] && cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [[ -n "$IDENTITY" ]]; then
  echo "==> Signing with \"$IDENTITY\""
  codesign --force --deep --options runtime --entitlements Packaging/Dictate.entitlements --sign "$IDENTITY" "$APP"
else
  echo "==> Signing ad hoc (macOS will ask for Accessibility again after every rebuild; see README)"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "==> Built $APP"
