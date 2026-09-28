#!/bin/bash
# Installs the Daisy plugin into Hermes and turns it on. It only acts in sessions Daisy starts
# (DAISY_SESSION=1): the Daisy persona, plus a yes-first gate for sends, deletes and calendar
# changes. Sign-in stays with Hermes; this script never touches its credentials.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES="$HERMES_HOME/hermes-agent/venv/bin/hermes"
[ -x "$HERMES" ] || HERMES="$(command -v hermes || true)"
if [ -z "$HERMES" ]; then
  echo "Hermes Agent isn't installed. Install it with:"
  echo "  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
  exit 1
fi
python3 "$REPO_DIR/hermes/test_daisy_guard.py"
DAISY_SESSION=1 "$HERMES" plugins doctor --ci "$REPO_DIR/hermes/daisy"
# The plugin was called jarvis until 2026-09-27; retire it, keeping a copy of config.yaml first.
if [ -d "$HERMES_HOME/plugins/jarvis" ]; then
  cp "$HERMES_HOME/config.yaml" "$HERMES_HOME/config.yaml.bak-$(date +%Y%m%d-%H%M%S)"
  "$HERMES" plugins disable jarvis >/dev/null 2>&1 || true
  rm -rf "$HERMES_HOME/plugins/jarvis"
fi
mkdir -p "$HERMES_HOME/plugins/daisy"
cp "$REPO_DIR/hermes/daisy/plugin.yaml" "$REPO_DIR/hermes/daisy/__init__.py" "$HERMES_HOME/plugins/daisy/"
"$HERMES" plugins enable daisy
echo "Daisy plugin installed in $HERMES_HOME/plugins/daisy and enabled."
echo "Not signed in to ChatGPT in Hermes yet? Run: hermes auth add openai-codex"
