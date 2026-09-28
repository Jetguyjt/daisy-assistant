#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VOICE_DIR="$HOME/Library/Application Support/Daisy/Runtime/voice"
PYTHON_BIN="${DAISY_PYTHON:-/opt/homebrew/bin/python3.11}"
if [ ! -x "$PYTHON_BIN" ]; then
  echo "Install Python 3.11 (brew install python@3.11), or set DAISY_PYTHON to a Python 3.10–3.13 executable."
  exit 1
fi
mkdir -p "$VOICE_DIR"
"$PYTHON_BIN" -m venv "$VOICE_DIR/venv"
"$VOICE_DIR/venv/bin/python" -m pip install --disable-pip-version-check 'kokoro-onnx==0.6.1' 'soundfile==0.13.1'
"$PYTHON_BIN" "$REPO_DIR/scripts/voice/download.py" "$VOICE_DIR"
cp "$REPO_DIR/scripts/voice/synthesize.py" "$VOICE_DIR/synthesize.py"
echo "Local Kokoro voice installed in $VOICE_DIR"
