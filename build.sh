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

echo "==> Rendering icon"
mkdir -p build
swift Resources/make-icon.swift build/Uncommitted.iconset >/dev/null
iconutil -c icns build/Uncommitted.iconset -o build/Uncommitted.icns

APP_STAGING="build/Uncommitted.app"
echo "==> Assembling $APP_STAGING"
rm -rf "$APP_STAGING"
mkdir -p "$APP_STAGING/Contents/MacOS" "$APP_STAGING/Contents/Resources"
cp "$BIN_SRC" "$APP_STAGING/Contents/MacOS/uncommitted"
# SPM doesn't add @executable_path/../Frameworks to the rpath, which
# Sparkle.framework needs to be found at runtime.
install_name_tool -add_rpath @executable_path/../Frameworks \
  "$APP_STAGING/Contents/MacOS/uncommitted" 2>/dev/null || true
cp Resources/Info.plist "$APP_STAGING/Contents/Info.plist"
cp build/Uncommitted.icns "$APP_STAGING/Contents/Resources/Uncommitted.icns"
printf "APPL????" > "$APP_STAGING/Contents/PkgInfo"

# SPM produces a resource bundle next to the binary when a target declares
# `resources:`. Copy it into the .app so Bundle.main.url(forResource:…)
# can find the SVG at runtime.
SPM_BUNDLE=".build/release/Uncommitted_Uncommitted.bundle"
if [ -d "$SPM_BUNDLE" ]; then
  cp -R "$SPM_BUNDLE" "$APP_STAGING/Contents/Resources/"
fi

# Sparkle framework (SPM binary artifact, inside an xcframework).
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  mkdir -p "$APP_STAGING/Contents/Frameworks"
  cp -R "$SPARKLE_FW" "$APP_STAGING/Contents/Frameworks/"
fi

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
