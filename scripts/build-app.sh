#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
BUILD_MODE="${1:-release}"
case "$BUILD_MODE" in release|debug) ;; *) echo "Use release or debug"; exit 1;; esac
swift build -c "$BUILD_MODE"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jarvis-build.XXXXXX")"
APP_DIR="$STAGING_DIR/Jarvis.app"
mkdir -p "$REPO_DIR/dist"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/$BUILD_MODE/Jarvis" "$APP_DIR/Contents/MacOS/Jarvis"
cp scripts/Info.plist "$APP_DIR/Contents/Info.plist"
python3 scripts/write-defaults.py "$REPO_DIR" "$APP_DIR/Contents/Resources/RuntimeDefaults.json"
# Finder/iCloud metadata on development folders can make ad-hoc signing fail.
xattr -cr "$APP_DIR"
codesign --force --sign - --identifier com.local.jarvis.desktop "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
# A zip survives iCloud/File Provider folders without Finder metadata altering the bundle.
ditto --norsrc --noextattr -c -k --keepParent "$APP_DIR" "$REPO_DIR/dist/Jarvis.zip"
ditto --norsrc --noextattr "$APP_DIR" "$REPO_DIR/dist/Jarvis.app"
echo "Built $REPO_DIR/dist/Jarvis.zip (verified in $STAGING_DIR)"
