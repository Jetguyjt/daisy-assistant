# Optional, off unless DAISY_CHROME_DEVTOOLS=1: chrome-devtools-mcp attached to my real Chrome
# (--autoConnect) as an MCP server, for clicking and filling forms, which the AppleScript tools can't do.
#
# Before turning it on: switch on remote debugging at chrome://inspect/#remote-debugging, and have
# Node 22+ on the PATH Hermes gets. Chrome asks before every debugging session (probably once per
# hermes-acp launch, not measured yet) and shows its "controlled by automated software" bar while
# it's attached. Page scripts stay off, and the guard asks before click, fill and press_key.
#
#   turn it on:  DAISY_CHROME_DEVTOOLS=1 bash scripts/setup-hermes.sh
#   take it out: hermes config unset mcp_servers.chrome_devtools
if [ "${DAISY_CHROME_DEVTOOLS:-0}" = 1 ]; then
  chrome_devtools_json() {  # chrome_devtools_json <dotted.key> <json>: config_set for a list or a map
    local current
    current="$("$HERMES" config get --json "$1" 2>/dev/null || true)"
    if [ "$current" != "$2" ]; then
      backup_config
      "$HERMES" config set "$1" "$2" >/dev/null
      echo "  set $1 = $2"
    fi
  }
  config_set mcp_servers.chrome_devtools.command npx
  chrome_devtools_json mcp_servers.chrome_devtools.args '["-y", "chrome-devtools-mcp@1.10.1", "--autoConnect", "--no-usage-statistics", "--no-performance-crux", "--no-javascript-evaluation", "--category-performance=false", "--category-network=false", "--category-emulation=false"]'
  chrome_devtools_json mcp_servers.chrome_devtools.env '{"CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS": "1", "CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS": "1"}'
  config_set mcp_servers.chrome_devtools.enabled true
  unset -f chrome_devtools_json
fi
