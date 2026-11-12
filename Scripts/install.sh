#!/usr/bin/env bash
# Builds a release Inky.app and installs it in ~/Applications, then (re)starts it.
# First run from there registers Inky to open at login (toggle in Settings).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=release Scripts/build-app.sh
DEST="$HOME/Applications/Inky.app"
mkdir -p "$HOME/Applications"
pkill -f "Inky.app/Contents/MacOS/Inky" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R build/Inky.app "$DEST"
open "$DEST"
echo "Installed $DEST"
