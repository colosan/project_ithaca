#!/usr/bin/env bash
# Installs dist/Ithaca.app (from build.sh) into /Applications for daily use.
#   tools/mac/install.sh [path/to/Ithaca.app]
# Quits the running app first and keeps the previous version in
# ~/Library/Application Support/Ithaca-Release/previous/ (restore = drag it back to /Applications).
# Data is not touched: it lives in ~/Library/Application Support/Ithaca/Library/ (ADR-0008).
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC="${1:-$PWD/dist/Ithaca.app}"
DST="${INSTALL_DIR:-/Applications}/Ithaca.app"
PREV="${PREVIOUS_DIR:-$HOME/Library/Application Support/Ithaca-Release/previous}"
BUNDLE_ID="io.github.colosan.ithaca"

[ -d "$SRC" ] || { echo "✗ $SRC not found — run tools/mac/build.sh first" >&2; exit 1; }
codesign --verify --deep --strict "$SRC"

if pgrep -qf "^$DST/Contents/MacOS/Ithaca"; then
  echo "▸ quitting Ithaca"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -qf "^$DST/Contents/MacOS/Ithaca" || break; sleep 0.2; done
  pgrep -qf "^$DST/Contents/MacOS/Ithaca" && { echo "✗ Ithaca is still running (unsaved dialog?) — quit it and retry" >&2; exit 1; }
fi

if [ -d "$DST" ]; then
  OLDV="$(defaults read "$DST/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown)"
  OLDB="$(defaults read "$DST/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo 0)"
  mkdir -p "$PREV"
  rm -rf "$PREV/Ithaca.app"
  ditto "$DST" "$PREV/Ithaca.app"
  echo "$OLDV ($OLDB)" > "$PREV/VERSION"
  echo "▸ kept previous $OLDV ($OLDB) in $PREV"
  rm -rf "$DST"
fi

ditto "$SRC" "$DST"
# A locally built copy carries no quarantine flag, but strip it in case the source came from a download.
xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
echo "✓ installed $(defaults read "$DST/Contents/Info.plist" CFBundleShortVersionString) ($(defaults read "$DST/Contents/Info.plist" CFBundleVersion)) → $DST"
open "$DST"
