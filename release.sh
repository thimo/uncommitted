#!/bin/bash
# Full release pipeline for Uncommitted.
#
# Usage:
#   ./release.sh 0.5.0            # build, sign, notarize, GitHub release
#   ./release.sh 0.5.0 --dry-run  # build only, ad-hoc sign, no upload
#
# Prerequisites:
#   - .env.local with UNCOMMITTED_SIGN_IDENTITY and
#     UNCOMMITTED_NOTARY_KEYCHAIN_PROFILE (see .env.example)
#   - `gh` CLI authenticated for thimo/uncommitted
#   - Sparkle EdDSA key in Keychain (via generate_keys, one-time)
#
# Without .env.local the script falls back to ad-hoc signing — useful
# for testing the build pipeline before the Apple Developer cert lands.
set -euo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>   e.g. $0 0.5.0" >&2
  exit 1
fi

DRY_RUN=false
for arg in "$@"; do
  [ "$arg" = "--dry-run" ] && DRY_RUN=true
done

# ---------------------------------------------------------------------------
# Load signing credentials (optional — graceful fallback)
# ---------------------------------------------------------------------------
SIGN_IDENTITY=""
NOTARY_PROFILE=""
if [ -f .env.local ]; then
  # shellcheck disable=SC1091
  set -a; source .env.local; set +a
  SIGN_IDENTITY="${UNCOMMITTED_SIGN_IDENTITY:-}"
  NOTARY_PROFILE="${UNCOMMITTED_NOTARY_KEYCHAIN_PROFILE:-}"
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Signing identity: $SIGN_IDENTITY"
else
  echo "==> No UNCOMMITTED_SIGN_IDENTITY — ad-hoc signing only."
fi

# ---------------------------------------------------------------------------
# Version bump in Info.plist
# ---------------------------------------------------------------------------
# CFBundleVersion = monotonically increasing build number from git.
# Sparkle uses this (not CFBundleShortVersionString) for comparisons.
BUILD_NUMBER=$(git rev-list --count HEAD)
echo "==> Version $VERSION (build $BUILD_NUMBER)"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER"       Resources/Info.plist

# ---------------------------------------------------------------------------
# Build universal binary (separate arches + lipo)
# ---------------------------------------------------------------------------
echo "==> Building arm64"
swift build -c release --arch arm64

echo "==> Building x86_64"
swift build -c release --arch x86_64

echo "==> Creating universal binary"
mkdir -p build
lipo -create -output build/uncommitted-universal \
  .build/arm64-apple-macosx/release/uncommitted \
  .build/x86_64-apple-macosx/release/uncommitted
lipo -info build/uncommitted-universal

# ---------------------------------------------------------------------------
# Render icon
# ---------------------------------------------------------------------------
echo "==> Rendering icon"
swift Resources/make-icon.swift build/Uncommitted.iconset >/dev/null
iconutil -c icns build/Uncommitted.iconset -o build/Uncommitted.icns

# ---------------------------------------------------------------------------
# Assemble .app bundle
# ---------------------------------------------------------------------------
APP="build/Uncommitted.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/uncommitted-universal "$APP/Contents/MacOS/uncommitted"
install_name_tool -add_rpath @executable_path/../Frameworks \
  "$APP/Contents/MacOS/uncommitted" 2>/dev/null || true
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/Uncommitted.icns "$APP/Contents/Resources/Uncommitted.icns"
printf "APPL????" > "$APP/Contents/PkgInfo"

# SPM resource bundles (use arm64 build — identical across arches).
SPM_BUNDLE=".build/arm64-apple-macosx/release/Uncommitted_Uncommitted.bundle"
if [ -d "$SPM_BUNDLE" ]; then
  cp -R "$SPM_BUNDLE" "$APP/Contents/Resources/"
fi

# Sparkle framework (from SPM binary artifact — lives inside an xcframework).
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  echo "==> Embedding Sparkle framework"
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
fi

# ---------------------------------------------------------------------------
# Code signing
# ---------------------------------------------------------------------------
if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Signing with Developer ID (hardened runtime + timestamp)"
  codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --entitlements Resources/Uncommitted.entitlements \
    --options runtime \
    --timestamp \
    "$APP"
else
  echo "==> Ad-hoc signing"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --verbose "$APP" 2>&1 | head -5

# ---------------------------------------------------------------------------
# Zip for distribution (ditto preserves code sig + extended attrs)
# ---------------------------------------------------------------------------
ZIP_NAME="Uncommitted-${VERSION}.zip"
ZIP_PATH="build/$ZIP_NAME"
echo "==> Creating $ZIP_PATH"
rm -f "$ZIP_PATH"
(cd build && ditto -c -k --keepParent Uncommitted.app "$ZIP_NAME")

# ---------------------------------------------------------------------------
# Notarize + staple (gated)
# ---------------------------------------------------------------------------
if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ] && [ "$DRY_RUN" = false ]; then
  echo "==> Submitting to notarytool…"
  xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "==> Stapling ticket"
  xcrun stapler staple "$APP"

  # Re-zip with the stapled ticket included.
  echo "==> Re-zipping with stapled ticket"
  rm -f "$ZIP_PATH"
  (cd build && ditto -c -k --keepParent Uncommitted.app "$ZIP_NAME")

  echo "==> Gatekeeper check"
  spctl --assess --type execute --verbose "$APP" 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Sparkle appcast
# ---------------------------------------------------------------------------
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
if [ -x "$SPARKLE_BIN/generate_appcast" ] && [ "$DRY_RUN" = false ]; then
  echo "==> Generating appcast.xml"
  "$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/thimo/uncommitted/releases/download/v${VERSION}/" \
    --link "https://github.com/thimo/uncommitted/releases/tag/v${VERSION}" \
    build/
  if [ -f build/appcast.xml ]; then
    cp build/appcast.xml appcast.xml
    echo "   appcast.xml updated in repo root."
  fi
else
  echo "   Skipping appcast — generate_appcast not found or --dry-run."
fi

# ---------------------------------------------------------------------------
# GitHub release
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = true ]; then
  echo
  echo "Done (dry run). Artifact: $ZIP_PATH"
  exit 0
fi

if command -v gh &>/dev/null; then
  TAG="v${VERSION}"
  echo "==> Creating GitHub release $TAG"
  if git rev-parse "$TAG" &>/dev/null; then
    echo "   Tag exists — uploading to existing release."
    gh release upload "$TAG" "$ZIP_PATH" --clobber
  else
    gh release create "$TAG" "$ZIP_PATH" \
      --title "Uncommitted ${VERSION}" \
      --generate-notes
  fi
  echo "   https://github.com/thimo/uncommitted/releases/tag/$TAG"
else
  echo "   gh CLI not found — upload $ZIP_PATH manually."
fi

# ---------------------------------------------------------------------------
# Commit version bump + appcast
# ---------------------------------------------------------------------------
if ! git diff --quiet Resources/Info.plist appcast.xml 2>/dev/null; then
  git add Resources/Info.plist
  [ -f appcast.xml ] && git add appcast.xml
  git commit -m "Release v${VERSION}"
  echo "==> Committed. Push to main when ready."
fi

echo
echo "Done. Uncommitted ${VERSION} at $ZIP_PATH"
