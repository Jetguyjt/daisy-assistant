# shellcheck shell=bash
# Messages and Reminders for Daisy's typed tools (hermes/daisy/tools/messages.py and apple.py): imsg sends texts
# through Messages, remindctl reads and changes Reminders through EventKit. Both come from steipete's Homebrew
# tap, and each family stays hidden until its CLI is there. Notes needs nothing extra: it goes through osascript.
# (memo, the CLI Hermes's apple-notes skill wants, isn't used; docs/INTEGRATIONS.md says why.)
#
# Nothing is installed unless DAISY_INSTALL_APPLE_CLIS=1. Otherwise this only says what's missing:
#   DAISY_INSTALL_APPLE_CLIS=1 bash scripts/setup-hermes.sh
apple_has() {  # apple_has <program>: on the PATH or in Homebrew's folders
  command -v "$1" >/dev/null 2>&1 || [ -x "/opt/homebrew/bin/$1" ] || [ -x "/usr/local/bin/$1" ]
}
apple_missing=""
apple_what=""
for apple_cli in imsg remindctl; do
  if ! apple_has "$apple_cli"; then
    apple_missing="$apple_missing steipete/tap/$apple_cli"
    case "$apple_cli" in imsg) apple_app=Messages ;; *) apple_app=Reminders ;; esac
    apple_what="${apple_what:+$apple_what and }$apple_app"
  fi
done
if [ -n "$apple_missing" ]; then
  apple_brew="$(command -v brew || true)"
  [ -n "$apple_brew" ] || { [ -x /opt/homebrew/bin/brew ] && apple_brew=/opt/homebrew/bin/brew; } || true
  # shellcheck disable=SC2086  # $apple_missing is one word per formula
  if [ "${DAISY_INSTALL_APPLE_CLIS:-0}" != 1 ]; then
    echo "  Daisy's $apple_what tools are off until this runs: brew install$apple_missing"
  elif [ -z "$apple_brew" ]; then
    echo "  Homebrew isn't installed, so$apple_missing can't be installed (https://brew.sh)"
  elif "$apple_brew" install $apple_missing; then
    echo "  installed$apple_missing"
  else
    echo "  brew install$apple_missing failed; Daisy's $apple_what tools stay off until it works"
  fi
fi
unset -f apple_has
unset apple_cli apple_app apple_missing apple_what apple_brew
