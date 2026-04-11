#!/bin/bash
# Build Uncommitted, wrap in a .app bundle, ad-hoc sign, install to
# ~/Applications/Uncommitted.app. Same pattern as Clawbridge.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building release binary"
swift build -c release

BIN_SRC=".build/release/uncommitted"
if [ ! -x "$BIN_SRC" ]; then
  echo "ERROR: build did not produce $BIN_SRC" >&2
  exit 1
fi

APP_STAGING="build/Uncommitted.app"
echo "==> Assembling $APP_STAGING"
rm -rf "$APP_STAGING"
mkdir -p "$APP_STAGING/Contents/MacOS" "$APP_STAGING/Contents/Resources"
cp "$BIN_SRC" "$APP_STAGING/Contents/MacOS/uncommitted"
cp Resources/Info.plist "$APP_STAGING/Contents/Info.plist"
printf "APPL????" > "$APP_STAGING/Contents/PkgInfo"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_STAGING"
codesign --verify --verbose "$APP_STAGING" 2>&1 | head -5

APP_INSTALL="$HOME/Applications/Uncommitted.app"
echo "==> Installing to $APP_INSTALL"
mkdir -p "$HOME/Applications"
# Quit any running instance so the bundle can be replaced cleanly.
killall -q uncommitted 2>/dev/null || true
sleep 0.2
rm -rf "$APP_INSTALL"
cp -R "$APP_STAGING" "$APP_INSTALL"

echo
echo "Done. Open $APP_INSTALL to run — it lives in the menu bar (no Dock icon)."
