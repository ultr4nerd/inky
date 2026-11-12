#!/usr/bin/env bash
# Builds Inky.app and signs it with a stable identity so macOS keeps the
# Accessibility permission across rebuilds.
# Override the identity with: INKY_SIGN_IDENTITY="Developer ID Application: ..." Scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-debug}"
swift build -c "$CONFIG"
APP="build/Inky.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c "$CONFIG" --show-bin-path)/Inky" "$APP/Contents/MacOS/Inky"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Default: SHA-1 of the first Developer ID Application identity, else the first Apple Development one
# (the hash avoids "ambiguous identity" errors when a certificate is duplicated in the keychain).
pick() { security find-identity -v -p codesigning | grep -v REVOKED | grep -m1 "$1" | awk '{print $2}' || true; }
IDENTITY="${INKY_SIGN_IDENTITY:-$(pick 'Developer ID Application')}"
IDENTITY="${IDENTITY:-$(pick 'Apple Development')}"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "Built $APP (signed: $IDENTITY)"
