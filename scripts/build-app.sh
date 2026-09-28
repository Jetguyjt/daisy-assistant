#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
BUILD_MODE="${1:-release}"
case "$BUILD_MODE" in release|debug) ;; *) echo "Use release or debug"; exit 1;; esac
# Only what the bundle needs: the test runner uses @testable imports, which a release build refuses.
swift build -c "$BUILD_MODE" --product Daisy
swift build -c "$BUILD_MODE" --product daisy-check
swift build -c "$BUILD_MODE" --product daisy-contacts
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/daisy-build.XXXXXX")"
APP_DIR="$STAGING_DIR/Daisy.app"
mkdir -p "$REPO_DIR/dist"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/$BUILD_MODE/Daisy" "$APP_DIR/Contents/MacOS/Daisy"
# The Contacts helper the Hermes plugin runs; signed before the bundle so --deep --strict passes.
cp ".build/$BUILD_MODE/daisy-contacts" "$APP_DIR/Contents/MacOS/daisy-contacts"
cp scripts/Info.plist "$APP_DIR/Contents/Info.plist"
ICONSET="$STAGING_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
".build/$BUILD_MODE/daisy-check" --render-icon "$STAGING_DIR/icon.png"
for px in 16 32 128 256 512; do
  sips -z $px $px "$STAGING_DIR/icon.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) "$STAGING_DIR/icon.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$STAGING_DIR/icon.png"
python3 scripts/write-defaults.py "$REPO_DIR" "$APP_DIR/Contents/Resources/RuntimeDefaults.json"
# Finder/iCloud metadata on development folders can make ad-hoc signing fail.
xattr -cr "$APP_DIR"
codesign --force --sign - --identifier com.local.daisy.contacts "$APP_DIR/Contents/MacOS/daisy-contacts"
codesign --force --sign - --identifier com.local.daisy.desktop "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
# A zip survives iCloud/File Provider folders without Finder metadata altering the bundle. Only the
# zip is kept here: a second Daisy.app in the repo shows up in Spotlight and the Dock next to the
# installed one in ~/Applications.
ditto --norsrc --noextattr -c -k --keepParent "$APP_DIR" "$REPO_DIR/dist/Daisy.zip"
rm -rf "$STAGING_DIR"
echo "Built $REPO_DIR/dist/Daisy.zip. Install it with scripts/install-app.sh."
