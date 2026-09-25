#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -f "$REPO_DIR/dist/Jarvis.zip" ]; then bash "$REPO_DIR/scripts/build-app.sh"; fi
INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"
# Runtime assets belong in app data, outside Documents/iCloud/TCC prompts.
# Preserve downloaded development assets and existing installed models.
RUNTIME_DIR="$HOME/Library/Application Support/Jarvis/Runtime"
mkdir -p "$RUNTIME_DIR/models" "$RUNTIME_DIR/ollama/models"
chmod 700 "$HOME/Library/Application Support/Jarvis" "$RUNTIME_DIR"
python3 "$REPO_DIR/scripts/install-models.py" "$REPO_DIR/.runtime" "$RUNTIME_DIR"
if [ -d "$RUNTIME_DIR/voice/venv" ]; then
  cp "$REPO_DIR/scripts/voice/synthesize.py" "$RUNTIME_DIR/voice/synthesize.py"
else
  echo "Natural speech is not installed yet. Run scripts/setup-voice.sh to enable it."
fi
if [ -e "$INSTALL_DIR/Jarvis.app" ]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INSTALL_DIR/Jarvis.app/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$EXISTING_ID" != "com.local.jarvis.desktop" ]; then
    echo "A different Jarvis.app already exists in $INSTALL_DIR. Move it before installing this app."
    exit 1
  fi
fi
ditto -x -k --norsrc --noextattr "$REPO_DIR/dist/Jarvis.zip" "$INSTALL_DIR"
codesign --verify --deep --strict "$INSTALL_DIR/Jarvis.app"
echo "Installed $INSTALL_DIR/Jarvis.app"
