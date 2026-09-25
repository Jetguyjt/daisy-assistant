#!/bin/bash
set -euo pipefail
umask 077
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
MODEL_TAG="${1:-qwen3.5:4b}"
case "$MODEL_TAG" in
  qwen3.5:2b|qwen3.5:4b|qwen3.5:9b) ;;
  *) echo "Supported benchmark downloads: qwen3.5:2b, qwen3.5:4b, qwen3.5:9b"; exit 1 ;;
esac
mkdir -p .runtime/models
if [ ! -s .runtime/models/ggml-base.en.bin ]; then
  curl -fL --retry 2 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin' -o .runtime/models/ggml-base.en.bin.part
  mv .runtime/models/ggml-base.en.bin.part .runtime/models/ggml-base.en.bin
fi
echo 'a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002  .runtime/models/ggml-base.en.bin' | shasum -a 256 -c -
OWNED_SERVER=""
cleanup() { if [ -n "$OWNED_SERVER" ]; then kill "$OWNED_SERVER" 2>/dev/null || true; fi; }
trap cleanup EXIT
if ! curl --noproxy '*' -fsS http://127.0.0.1:11435/api/version >/dev/null 2>&1; then
  bash scripts/serve-model.sh >.runtime/setup-engine.log 2>&1 &
  OWNED_SERVER=$!
  for i in {1..40}; do
    if curl --noproxy '*' -fsS http://127.0.0.1:11435/api/version >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
fi
echo "Downloading $MODEL_TAG locally. This can take a few minutes."
export OLLAMA_HOST=127.0.0.1:11435
ollama pull "$MODEL_TAG"
