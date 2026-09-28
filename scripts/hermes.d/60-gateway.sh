# shellcheck shell=bash
# The always-on layer: Hermes's gateway as a LaunchAgent, so scheduled jobs (hermes cron) and the Kanban
# dispatcher keep running while Daisy is closed. Off unless asked, since it's a process that's always up
# and starts at login.
#
#   turn it on:  DAISY_GATEWAY=1 bash scripts/setup-hermes.sh
#   take it out: DAISY_GATEWAY=0 bash scripts/setup-hermes.sh   (runs hermes gateway uninstall)
#   check it:    hermes gateway status
#
# Hermes does the work (launchd_install in hermes_cli/gateway.py): it writes
# ~/Library/LaunchAgents/ai.hermes.gateway.plist (hermes gateway run --external-supervisor, RunAtLoad,
# KeepAlive, restarts at most every 30s, HERMES_HOME and a PATH with Hermes's venv first, logs in
# $HERMES_HOME/logs/gateway.log) and loads it with launchctl bootstrap. Running it again changes nothing,
# or repairs a definition a Hermes update made stale. With no messaging platform set up the gateway stays
# up for cron. It loads the Daisy plugin from $HERMES_HOME/plugins like every Hermes process, and the
# guard treats each cron run as read-only (hermes/daisy/guard/roles.py). A closed lid on battery still
# means sleep: jobs that were due run once when the Mac wakes.
# shellcheck source=scripts/alwayson/lib.sh
. "$REPO_DIR/scripts/alwayson/lib.sh"
case "${DAISY_GATEWAY:-}" in
  1)
    "$HERMES" gateway install | sed 's/^/  /'
    ;;
  0)
    if [ -f "$(daisy_gateway_plist)" ]; then
      "$HERMES" gateway uninstall | sed 's/^/  /'
    else
      echo "  gateway: not installed"
    fi
    ;;
  *)
    if [ -f "$(daisy_gateway_plist)" ]; then
      echo "  gateway: installed as a LaunchAgent (DAISY_GATEWAY=0 takes it out)"
    else
      echo "  gateway: off; DAISY_GATEWAY=1 installs it as a LaunchAgent so scheduled jobs run while Daisy is closed"
    fi
    ;;
esac
