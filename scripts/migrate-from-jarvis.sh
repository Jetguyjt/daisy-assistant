#!/bin/bash
# One-time move from the old Jarvis name. Safe to run again: it does nothing once Daisy's folder exists.
# Backs up the old data folder first (an APFS clone, so it costs no extra space until something changes).
set -euo pipefail
SUPPORT="$HOME/Library/Application Support"
OLD="$SUPPORT/Jarvis"
NEW="$SUPPORT/Daisy"
if [ -d "$OLD" ] && [ ! -e "$NEW" ]; then
  BACKUP="$SUPPORT/Jarvis.backup-$(date +%Y%m%d-%H%M%S)"
  cp -cR "$OLD" "$BACKUP" 2>/dev/null || ditto "$OLD" "$BACKUP"
  mv "$OLD" "$NEW"
  python3 - "$OLD" "$NEW" <<'PY'
import sys, pathlib
old, new = sys.argv[1], sys.argv[2]
config = pathlib.Path(new) / "config.json"
if config.exists():
    text = config.read_text()
    for a, b in ((old, new), (old.replace("/", "\\/"), new.replace("/", "\\/"))):
        text = text.replace(a, b)
    config.write_text(text)
PY
  echo "Moved $OLD to $NEW (backup at $BACKUP)."
else
  echo "Nothing to move."
fi
