# shellcheck shell=bash
# Budget for the always-on layer, with the gateway (DAISY_GATEWAY=1). Everything shares one ChatGPT
# plan, so subagents that delegate_task starts in cron and gateway runs (where delegation works; Daisy's
# own sessions don't use it) run on a cheaper model. delegation.model becomes the newest "mini" model
# Hermes lists for the current provider (scripts/alwayson/models.py, the same list `hermes model` shows),
# never a name written down here. When nothing cheaper is listed it stays as it is, and this says why.
# Listing can make one network request, the same one `hermes model` makes.
#
#   clear it:    hermes config unset delegation.model
#
# The Daisy app polls the 5-hour and weekly usage windows through Hermes and holds new background jobs
# at 80%. No fallback provider is set here on purpose; that's my call (`hermes fallback add`, options in
# docs/research/orchestrator.md).
# shellcheck source=scripts/alwayson/lib.sh
. "$REPO_DIR/scripts/alwayson/lib.sh"
case "${DAISY_GATEWAY:-}" in
  1)
    daisy_pick_model
    if [ -n "$DAISY_MODEL" ]; then
      config_set delegation.model "$DAISY_MODEL"
    else
      echo "  budget: delegation.model left as it is ($DAISY_MODEL_WHY)"
    fi
    ;;
  0)
    budget_model="$("$HERMES" config get delegation.model 2>/dev/null || true)"
    if [ -n "$budget_model" ]; then
      echo "  budget: delegation.model is still $budget_model (hermes config unset delegation.model clears it)"
    fi
    unset budget_model
    ;;
esac
