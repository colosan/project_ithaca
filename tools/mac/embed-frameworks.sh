#!/usr/bin/env bash
# Called by build.sh: copies Sparkle.framework into Ithaca.app/Contents/Frameworks and signs it inside-out.
#   tools/mac/embed-frameworks.sh <swiftpm-bin-dir> <Ithaca.app>
# SIGN_IDENTITY (from build.sh) is "-" for ad-hoc or a keychain identity name.
# The app finds the framework via the rpath @executable_path/../Frameworks set in swift/Package.swift.
set -euo pipefail
BIN="$1"; APP="$2"
ID="${SIGN_IDENTITY:--}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

SRC="$BIN/Sparkle.framework"
if [ ! -d "$SRC" ]; then
  SRC="$(find "$ROOT/swift/.build/artifacts" -path '*Sparkle.xcframework/macos-*/Sparkle.framework' -maxdepth 6 -type d 2>/dev/null | head -1)"
fi
[ -d "$SRC" ] || { echo "✗ Sparkle.framework not found (run: cd swift && swift package resolve)" >&2; exit 1; }

DST="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$DST"
ditto "$SRC" "$DST"   # ditto keeps the Versions/Current symlinks intact
# Headers and module maps are build-time only.
rm -rf "$DST/Versions/B/Headers" "$DST/Versions/B/PrivateHeaders" "$DST/Versions/B/Modules" \
       "$DST/Headers" "$DST/PrivateHeaders" "$DST/Modules"

# Inside-out, as Sparkle's docs prescribe for builds outside Xcode. No --deep, no hardened runtime unless
# Developer ID (hardened runtime + library validation refuses frameworks without a matching Team ID).
OPTS=(--force --sign "$ID" --timestamp=none)
case "$ID" in "Developer ID"*) OPTS=(--force --sign "$ID" --options runtime --timestamp) ;; esac
V="$DST/Versions/B"
[ -d "$V/XPCServices/Installer.xpc" ] && codesign "${OPTS[@]}" "$V/XPCServices/Installer.xpc"
[ -d "$V/XPCServices/Downloader.xpc" ] && codesign "${OPTS[@]}" --preserve-metadata=entitlements "$V/XPCServices/Downloader.xpc"
codesign "${OPTS[@]}" "$V/Autoupdate"
codesign "${OPTS[@]}" "$V/Updater.app"
codesign "${OPTS[@]}" "$DST"
echo "  embedded Sparkle.framework ($(defaults read "$DST/Resources/Info.plist" CFBundleShortVersionString))"
