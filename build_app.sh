#!/bin/bash
# Assembles and signs WindowKeeper.app: Developer ID, hardened runtime, not sandboxed.
#
# A stable Developer ID signature matters beyond distribution: the Accessibility grant is
# tied to the app's designated requirement, which for an ad-hoc signature includes the
# code hash and so would be revoked by every rebuild.
set -euo pipefail

APP_NAME="WindowKeeper"
BUNDLE_ID="com.smanke.WindowKeeper"
ROOT="$(cd "$(dirname "$0")" && pwd)"
IDENTITY="${1:-}"
BUILD="$ROOT/.build/app"
APP="$BUILD/$APP_NAME.app"
SWIFT_ARGS=(-c release --arch arm64 --arch x86_64)

# Ask SwiftPM where the product goes rather than assuming: Swift 6.4 moved it, and a
# leftover binary at the old path once shipped days-old code inside a freshly versioned
# bundle. Delete the product first and require the build to write it again, so whatever
# is packaged is provably from this build.
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
rm -f "$BIN_DIR/$APP_NAME"
MARKER="$(mktemp)"
trap 'rm -f "$MARKER"' EXIT
sleep 1

echo "==> Building universal binary"
swift build "${SWIFT_ARGS[@]}"
if [ ! -x "$BIN_DIR/$APP_NAME" ] || [ ! "$BIN_DIR/$APP_NAME" -nt "$MARKER" ]; then
  echo "The build did not produce a fresh $BIN_DIR/$APP_NAME — refusing to package." >&2
  exit 1
fi
echo "    using $BIN_DIR"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cmp -s "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME" || { echo "Bundled binary differs from the build product." >&2; exit 1; }
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "==> Resolving signing identity"
if [ -z "$IDENTITY" ]; then
  FOUND=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
  if [ -z "$FOUND" ]; then
    echo "No Developer ID Application identity found in the keychain." >&2
    exit 1
  fi
  IDENTITY=$(echo "$FOUND" | sed -E 's/.*"(.*)"$/\1/')
fi
echo "    $IDENTITY"

echo "==> Signing"
# Keep the .entitlements file free of XML comments: plutil accepts them, but codesign's
# AMFI parser rejects the file.
codesign --force --options runtime --timestamp \
  --identifier "$BUNDLE_ID" \
  --entitlements "$ROOT/Resources/WindowKeeper.entitlements" \
  --sign "$IDENTITY" \
  "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"

echo
echo "Built $APP ($VERSION)"
