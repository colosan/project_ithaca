#!/usr/bin/env bash
# Builds Ithaca.app without Xcode (ADR-0008): Rust core → UniFFI Swift bindings → SwiftPM → .app bundle.
#   tools/mac/build.sh            release build into dist/Ithaca.app
#   BUILD=123 tools/mac/build.sh  override the build number (default: commit count)
#   SIGN_IDENTITY="…" tools/mac/build.sh  sign with a keychain identity (default: the one named in
#     ~/Library/Application Support/Ithaca-Release/signing-identity, written by make-signing-identity.sh; else ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

VERSION="$(cat VERSION)"
BUILD="${BUILD:-$(git rev-list --count HEAD)}"
APP="$ROOT/dist/Ithaca.app"

echo "▸ core (Rust)"
(cd core && cargo build --release -p ithaca-ffi)

echo "▸ bindings (UniFFI → Swift)"
OUT="$ROOT/core/target/swift-bindings"
(cd core && cargo run -q --release --bin uniffi-bindgen -- generate --library target/release/libithaca_ffi.a --language swift --out-dir "$OUT")
FFI="$ROOT/swift/Sources/IthacaCoreFFI/include"
mkdir -p "$FFI"
cp "$OUT/ithaca_ffiFFI.h" "$FFI/"
sed 's/^module ithaca_ffiFFI/module IthacaCoreFFI/' "$OUT/ithaca_ffiFFI.modulemap" > "$FFI/module.modulemap"
sed 's/canImport(ithaca_ffiFFI)/canImport(IthacaCoreFFI)/; s/import ithaca_ffiFFI/import IthacaCoreFFI/' "$OUT/ithaca_ffi.swift" > "$ROOT/swift/Sources/IthacaCore/Generated_ithaca_ffi.swift"

echo "▸ app (SwiftPM)"
# --disable-keychain: SwiftPM otherwise looks up github.com credentials in the keychain and can block on a dialog.
(cd swift && swift build --disable-keychain -c release --product Ithaca)
BIN="$(cd swift && swift build --disable-keychain -c release --show-bin-path)"

echo "▸ bundle $APP ($VERSION build $BUILD)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Ithaca" "$APP/Contents/MacOS/Ithaca"
sed "s/__VERSION__/$VERSION/; s/__BUILD__/$BUILD/" swift/Apps/macOS/Info.plist > "$APP/Contents/Info.plist"
# SwiftPM resource bundles (design assets etc.) sit next to the binary.
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
[ -f swift/Apps/macOS/AppIcon.icns ] && cp swift/Apps/macOS/AppIcon.icns "$APP/Contents/Resources/"

MARKER="$HOME/Library/Application Support/Ithaca-Release/signing-identity"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="-"
  [ -f "$MARKER" ] && SIGN_IDENTITY="$(head -1 "$MARKER")"
fi
export SIGN_IDENTITY
# Embedded frameworks (Sparkle): copied and signed inside-out by the hook.
if [ -x tools/mac/embed-frameworks.sh ]; then tools/mac/embed-frameworks.sh "$BIN" "$APP"; fi

# Nested code is already signed, so no --deep. Hardened runtime only with Developer ID (notarization needs it;
# with ad-hoc / self-signed it makes library validation refuse Sparkle.framework).
echo "▸ sign (${SIGN_IDENTITY/#-/ad-hoc})"
case "$SIGN_IDENTITY" in
  "Developer ID"*) codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP" ;;
  *) codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP" ;;
esac
codesign --verify --deep --strict "$APP"
echo "✓ $APP"
