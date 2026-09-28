#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Always build first, so what gets installed is the code as it is now, not an old zip.
bash "$REPO_DIR/scripts/build-app.sh"
INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"
# Before anything creates Daisy's folder, carry over the old Jarvis one.
bash "$REPO_DIR/scripts/migrate-from-jarvis.sh"
# Runtime assets belong in app data, outside Documents/iCloud/TCC prompts.
# Preserve downloaded development assets and existing installed models.
RUNTIME_DIR="$HOME/Library/Application Support/Daisy/Runtime"
mkdir -p "$RUNTIME_DIR/models" "$RUNTIME_DIR/ollama/models"
chmod 700 "$HOME/Library/Application Support/Daisy" "$RUNTIME_DIR"
python3 "$REPO_DIR/scripts/install-models.py" "$REPO_DIR/.runtime" "$RUNTIME_DIR"
if [ -d "$RUNTIME_DIR/voice/venv" ]; then
  cp "$REPO_DIR/scripts/voice/synthesize.py" "$RUNTIME_DIR/voice/synthesize.py"
else
  echo "Natural speech is not installed yet. Run scripts/setup-voice.sh to enable it."
fi
if [ -e "$INSTALL_DIR/Daisy.app" ]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INSTALL_DIR/Daisy.app/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$EXISTING_ID" != "com.local.daisy.desktop" ]; then
    echo "A different Daisy.app already exists in $INSTALL_DIR. Move it before installing this app."
    exit 1
  fi
fi
ditto -x -k --norsrc --noextattr "$REPO_DIR/dist/Daisy.zip" "$INSTALL_DIR"
codesign --verify --deep --strict "$INSTALL_DIR/Daisy.app"
# ~/Applications/Daisy.app is the only copy; tell Launch Services about the new build.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/Daisy.app" || true
echo "Installed $INSTALL_DIR/Daisy.app"
