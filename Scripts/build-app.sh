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
# Identity: $INKY_SIGN_IDENTITY, else .signing-identity (gitignored, a SHA-1), else the first
# Developer ID / Apple Development identity that isn't revoked. Signing with a revoked
# certificate makes macOS flag the app as malware and move it to the Trash.
revoked() {
  local tmp; tmp=$(mktemp -d)
  cp -R "$APP" "$tmp/t.app"
  codesign --force --options runtime --sign "$1" "$tmp/t.app" 2>/dev/null
  spctl -a -t exec "$tmp/t.app" 2>&1 | grep -q REVOKED; local r=$?
  rm -rf "$tmp"; return $((1 - r))
}
IDENTITY="${INKY_SIGN_IDENTITY:-}"
[[ -z "$IDENTITY" && -f .signing-identity ]] && IDENTITY="$(tr -d '[:space:]' < .signing-identity)"
if [[ -z "$IDENTITY" ]]; then
  for kind in 'Developer ID Application' 'Apple Development'; do
    for h in $(security find-identity -v -p codesigning | grep "$kind" | grep -v REVOKED | awk '{print $2}'); do
      if ! revoked "$h"; then IDENTITY="$h"; break 2; fi
    done
  done
fi
[[ -n "$IDENTITY" ]] || { echo "No valid signing identity found." >&2; exit 1; }
codesign --force --options runtime --sign "$IDENTITY" "$APP"
if spctl -a -t exec "$APP" 2>&1 | grep -q REVOKED; then
  echo "Signing certificate $IDENTITY is revoked. Pick another (security find-identity -v -p codesigning)." >&2
  rm -rf "$APP"; exit 1
fi
echo "Built $APP (signed: $IDENTITY)"
