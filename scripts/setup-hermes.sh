#!/bin/bash
# Installs the Jarvis plugin into Hermes and turns it on. It only acts in sessions Jarvis starts
# (JARVIS_SESSION=1): the Jarvis persona, plus a yes-first gate for sends, deletes and calendar
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
python3 "$REPO_DIR/hermes/test_jarvis_guard.py"
JARVIS_SESSION=1 "$HERMES" plugins doctor --ci "$REPO_DIR/hermes/jarvis"
mkdir -p "$HERMES_HOME/plugins/jarvis"
cp "$REPO_DIR/hermes/jarvis/plugin.yaml" "$REPO_DIR/hermes/jarvis/__init__.py" "$HERMES_HOME/plugins/jarvis/"
"$HERMES" plugins enable jarvis
echo "Jarvis plugin installed in $HERMES_HOME/plugins/jarvis and enabled."
echo "Not signed in to ChatGPT in Hermes yet? Run: hermes auth add openai-codex"
