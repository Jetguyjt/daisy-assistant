# shellcheck shell=bash
# Shared by the always-on fragments in scripts/hermes.d (gateway, budget, cron). Sourced; it only
# defines functions and changes nothing. Needs $HERMES, $HERMES_HOME and $REPO_DIR from setup-hermes.sh.

# Hermes's own Python: the venv the hermes command runs from.
daisy_hermes_python() {
  local candidate
  for candidate in "$(dirname "$HERMES")/python" "$HERMES_HOME/hermes-agent/venv/bin/python"; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Sets DAISY_MODEL (empty when nothing cheaper is listed), DAISY_PROVIDER and DAISY_MODEL_WHY, once per
# setup run. The rule is scripts/alwayson/models.py; the list is what `hermes model` offers.
daisy_pick_model() {
  if [ -n "${DAISY_MODEL_WHY:-}" ]; then return 0; fi
  DAISY_MODEL=""
  DAISY_PROVIDER=""
  local python listing
  if ! python="$(daisy_hermes_python)"; then
    DAISY_MODEL_WHY="Hermes's Python wasn't found"
    return 0
  fi
  if ! listing="$("$python" -I -B "$REPO_DIR/scripts/alwayson/models.py" list 2>/dev/null)"; then
    DAISY_MODEL_WHY="Hermes couldn't list its models"
    return 0
  fi
  {
    IFS= read -r DAISY_MODEL || true
    IFS= read -r DAISY_PROVIDER || true
    IFS= read -r DAISY_MODEL_WHY || true
  } < <(printf '%s' "$listing" | python3 "$REPO_DIR/scripts/alwayson/models.py" pick)
  DAISY_MODEL_WHY="${DAISY_MODEL_WHY:-no reason given}"
}

# Where `hermes gateway install` puts the LaunchAgent for the default profile.
daisy_gateway_plist() {
  echo "$HOME/Library/LaunchAgents/ai.hermes.gateway.plist"
}
