# shellcheck shell=bash
# Scheduled jobs from hermes/cron/*.md. Both only read, and their output lands in
# $HERMES_HOME/cron/output/ for Daisy's JOBS tab; nothing is sent anywhere. Off unless asked:
#
#   add them:      DAISY_CRON=1 bash scripts/setup-hermes.sh
#   take them out: DAISY_CRON=0 bash scripts/setup-hermes.sh
#
# - Daisy inbox triage, 5:30 every morning: unread mail from the last day through the google-workspace
#   skill's google_api.py gmail search, sorted into needs a reply / FYI / can wait, one line each, no
#   bodies. If Google isn't connected it says so in one line.
# - Daisy repo digest, 7:00: branch, uncommitted changes, last commits and where I left off, for the
#   folders in $HERMES_HOME/daisy/repo-digest.txt (one per line, empty to start). Its script,
#   daisy-repo-digest.py, goes in $HERMES_HOME/scripts and runs first; with no folders it skips the
#   model, so it costs nothing.
#
# They only fire while the gateway runs (60-gateway.sh), and the Daisy guard lets a cron run read and
# nothing else. When 61-budget.sh's rule finds a cheaper model, the jobs are pinned to it (low reasoning
# effort either way). Setup puts the prompts back when they drift from the repo but leaves schedules
# alone once a job exists: `hermes cron edit <id> --schedule '0 6 * * *'` changes one.
# shellcheck source=scripts/alwayson/lib.sh
. "$REPO_DIR/scripts/alwayson/lib.sh"
case "${DAISY_CRON:-}" in
  1)
    cron_list="$HERMES_HOME/daisy/repo-digest.txt"
    if [ ! -f "$cron_list" ]; then
      mkdir -p "$HERMES_HOME/daisy"
      printf '%s\n' "# Folders for Daisy's morning repo digest, one per line. ~ is fine; # starts a comment." > "$cron_list"
      echo "  created $cron_list (add folders to it to get a digest)"
    fi
    cron_script="$HERMES_HOME/scripts/daisy-repo-digest.py"
    if ! cmp -s "$REPO_DIR/hermes/cron/scripts/daisy-repo-digest.py" "$cron_script"; then
      mkdir -p "$HERMES_HOME/scripts"
      cp "$REPO_DIR/hermes/cron/scripts/daisy-repo-digest.py" "$cron_script"
      echo "  installed $cron_script"
    fi
    daisy_pick_model
    if [ -z "$DAISY_MODEL" ]; then
      echo "  cron: jobs follow the default model ($DAISY_MODEL_WHY)"
    fi
    python3 "$REPO_DIR/scripts/alwayson/cron_jobs.py" add --hermes "$HERMES" --home "$HERMES_HOME" \
      --templates "$REPO_DIR/hermes/cron" --model "$DAISY_MODEL" --provider "$DAISY_PROVIDER" \
      || echo "  cron: not every job went in; see above"
    if [ ! -f "$(daisy_gateway_plist)" ]; then
      echo "  cron: the jobs only fire while the gateway runs (DAISY_GATEWAY=1)"
    fi
    unset cron_list cron_script
    ;;
  0)
    python3 "$REPO_DIR/scripts/alwayson/cron_jobs.py" remove --hermes "$HERMES" --home "$HERMES_HOME" \
      --templates "$REPO_DIR/hermes/cron" || echo "  cron: not every job came out; see above"
    ;;
  *)
    python3 "$REPO_DIR/scripts/alwayson/cron_jobs.py" status --home "$HERMES_HOME" --templates "$REPO_DIR/hermes/cron"
    ;;
esac
