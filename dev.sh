#!/bin/bash
# Fast dev iteration: rebuild the Swift binary and drop it into the
# already-installed .app bundle at ~/Applications/Uncommitted.app.
# Skips icon rendering, Sparkle copy, and bundle reassembly — use
# `build.sh` for a clean full install when resources or frameworks change.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Uncommitted.app"
if [ ! -d "$APP" ]; then
  echo "ERROR: $APP not found — run ./build.sh first for a full install." >&2
  exit 1
fi

echo "==> swift build (debug)"
swift build

BIN_SRC=".build/debug/uncommitted"
BIN_DST="$APP/Contents/MacOS/uncommitted"

echo "==> Replacing binary in $APP"
killall -q uncommitted 2>/dev/null || true
cp "$BIN_SRC" "$BIN_DST"
# SPM binary doesn't have the Sparkle rpath; add it fresh on each copy.
install_name_tool -add_rpath @executable_path/../Frameworks "$BIN_DST" 2>/dev/null || true

echo "==> Re-signing"
codesign --force --deep --sign - "$APP" 2>&1 | tail -1

# Touch the bundle so Finder shows a fresh modification date. macOS
# does not propagate child-file mtimes up to the directory, so without
# this the .app keeps whatever mtime it had from the last build.sh run.
touch "$APP"

echo
echo "Done. Launch $APP."
