#!/bin/bash
# Installs the Daisy plugin into Hermes and turns it on, then applies every config fragment in
# scripts/hermes.d/. The approval guard loads in every Hermes process (Daisy, CLI, gateway, cron);
# the Daisy persona and typed tools only in sessions Daisy starts (DAISY_SESSION=1). Sign-in stays
# with Hermes; this script never reads or touches its credentials.
#
# Fragments (scripts/hermes.d/NN-name.sh) are sourced in order. They must be idempotent: check
# before changing, and use config_set, which only writes when the value differs and backs up
# config.yaml once per run before the first change.
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

BACKED_UP=0
backup_config() {
  if [ "$BACKED_UP" = 0 ] && [ -f "$HERMES_HOME/config.yaml" ]; then
    cp "$HERMES_HOME/config.yaml" "$HERMES_HOME/config.yaml.bak-$(date +%Y%m%d-%H%M%S)"
    BACKED_UP=1
  fi
}
config_set() {  # config_set <dotted.key> <value>
  local current
  current="$("$HERMES" config get "$1" 2>/dev/null || true)"
  if [ "$current" != "$2" ]; then
    backup_config
    "$HERMES" config set "$1" "$2" >/dev/null
    echo "  set $1 = $2"
  fi
}

for test in "$REPO_DIR"/hermes/test_*.py; do python3 "$test"; done
find "$REPO_DIR/hermes" -name __pycache__ -type d -prune -exec rm -rf {} +
DAISY_SESSION=1 "$HERMES" plugins doctor --ci "$REPO_DIR/hermes/daisy"

# The plugin was called jarvis until 2026-09-27; retire it.
if [ -d "$HERMES_HOME/plugins/jarvis" ]; then
  backup_config
  "$HERMES" plugins disable jarvis >/dev/null 2>&1 || true
  rm -rf "$HERMES_HOME/plugins/jarvis"
fi
mkdir -p "$HERMES_HOME/plugins/daisy"
rsync -a --delete --exclude __pycache__ "$REPO_DIR/hermes/daisy/" "$HERMES_HOME/plugins/daisy/"
"$HERMES" plugins enable daisy >/dev/null 2>&1 || true

for fragment in "$REPO_DIR"/scripts/hermes.d/*.sh; do
  [ -e "$fragment" ] || continue
  echo "== $(basename "$fragment")"
  # shellcheck source=/dev/null
  source "$fragment"
done

echo "Daisy plugin installed in $HERMES_HOME/plugins/daisy and enabled."
echo "Not signed in to ChatGPT in Hermes yet? Run: hermes auth add openai-codex"
