#!/bin/bash
# Speech-in models for Daisy, into the app's Runtime folder. Safe to run again: files already there
# with the right checksum are left alone. Everything comes from GitHub, pinned and checked, never
# from Hugging Face. Apple's recognizer model isn't here: Daisy asks Apple for it on first use.
#   bash scripts/setup-speech.sh
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPEECH_DIR="${DAISY_SPEECH_DIR:-$HOME/Library/Application Support/Daisy/Runtime/speech}"
VOICE_PYTHON="${DAISY_VOICE_PYTHON:-$HOME/Library/Application Support/Daisy/Runtime/voice/venv/bin/python}"
mkdir -p "$SPEECH_DIR"
chmod 700 "$SPEECH_DIR"

# fetch <file> <url> <sha256>
fetch() {
  local target="$SPEECH_DIR/$1"
  if [ -f "$target" ] && echo "$3  $target" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "Have $1"
    return
  fi
  echo "Downloading $1"
  curl -fsSL --retry 2 --proto '=https' -o "$target.download" "$2"
  if ! echo "$3  $target.download" | shasum -a 256 -c - >/dev/null 2>&1; then
    rm -f "$target.download"
    echo "Checksum mismatch for $1; nothing was installed." >&2
    exit 1
  fi
  mv "$target.download" "$target"
}

# Silero VAD v6.2, 16 kHz only (MIT). Daisy runs it in Swift, so it needs no Python.
fetch silero_vad_16k_op15.onnx \
  "https://raw.githubusercontent.com/snakers4/silero-vad/v6.2.3/src/silero_vad/data/silero_vad_16k_op15.onnx" \
  7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49

# openWakeWord's shared feature models (Apache 2.0). Only used once a hey_daisy.onnx is added.
fetch melspectrogram.onnx \
  "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/melspectrogram.onnx" \
  ba2b0e0f8b7b875369a2c89cb13360ff53bac436f2895cced9f479fa65eb176f
fetch embedding_model.onnx \
  "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/embedding_model.onnx" \
  70d164290c1d095d1d4ee149bc5e00543250a7316b59f31d056cff7bd3075c1f
install -m 0644 "$REPO_DIR/scripts/speech/wakeword.py" "$SPEECH_DIR/wakeword.py"

echo "Speech models are in $SPEECH_DIR"
if [ -f "$SPEECH_DIR/hey_daisy.onnx" ]; then
  echo "Wake word: hey_daisy.onnx is there, so it's the first stage."
else
  echo "Wake word: no hey_daisy.onnx yet, so the recognizer listens for \"Hey Daisy\". To train one, see docs/wake-word.md."
fi
if [ -x "$VOICE_PYTHON" ] && PYTHONDONTWRITEBYTECODE=1 "$VOICE_PYTHON" -c "import numpy, onnxruntime" >/dev/null 2>&1; then
  echo "The wake word model will run in the voice venv's Python."
else
  echo "The wake word model runs in the voice venv; run scripts/setup-voice.sh before adding hey_daisy.onnx."
fi
echo "Restart Daisy (or turn always listening off and on) to pick these up."
