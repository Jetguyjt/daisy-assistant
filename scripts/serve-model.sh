#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export OLLAMA_HOST=127.0.0.1:11435
export OLLAMA_NO_CLOUD=1
export OLLAMA_MODELS="$REPO_DIR/.runtime/ollama/models"
export OLLAMA_CONTEXT_LENGTH=16384
export OLLAMA_NUM_PARALLEL=1
export OLLAMA_DEBUG_LOG_REQUESTS=false
exec "$(command -v ollama)" serve
