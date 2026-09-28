# Chrome: the daisy-chrome skill ("check my email" is one chrome_open call, reuse an open tab before
# opening a new one). The tools come with the plugin (hermes/daisy/tools/chrome.py). It goes next to
# the other Mac skills, and the repo copy wins over any edits Hermes made to it.
chrome_skill="$HERMES_HOME/skills/apple/daisy-chrome"
if ! diff -rq -x .DS_Store "$REPO_DIR/hermes/skills/daisy-chrome" "$chrome_skill" >/dev/null 2>&1; then
  mkdir -p "$chrome_skill"
  rsync -a --delete --exclude .DS_Store "$REPO_DIR/hermes/skills/daisy-chrome/" "$chrome_skill/"
  echo "  installed skill apple/daisy-chrome"
fi
unset chrome_skill
