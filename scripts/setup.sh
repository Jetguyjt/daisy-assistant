#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Install Apple's command line tools with xcode-select --install, then rerun this script."
  exit 1
fi
if ! command -v brew >/dev/null; then
  echo "Install Homebrew from https://brew.sh first, then rerun this script."
  exit 1
fi
export HOMEBREW_NO_AUTO_UPDATE=1
brew install ollama whisper-cpp python@3.11
bash scripts/download-models.sh
bash scripts/setup-voice.sh
if command -v node >/dev/null && command -v npm >/dev/null; then bash scripts/setup-browser.sh; else echo "Chrome connection needs Node 22.12+ and npm; run scripts/setup-browser.sh after installing them."; fi
bash scripts/build-app.sh
bash scripts/install-app.sh
echo "Ready. Open ~/Applications/Daisy.app, then choose a folder."
