# Hermes config fragments

`scripts/setup-hermes.sh` sources every `NN-name.sh` here, in order, after installing the plugin.

- One fragment per feature (`10-memory.sh`, `20-google.sh`, ...).
- Idempotent: running setup twice changes nothing the second time.
- Change settings with `config_set <dotted.key> <value>`. It only writes when the value differs, and backs up `~/.hermes/config.yaml` once per run before the first change.
- Anything else that edits `config.yaml` calls `backup_config` first.
- Never read or print credentials (`auth.json`, `google_token.json`, `.env`).
- Available: `$HERMES` (the CLI), `$HERMES_HOME`, `$REPO_DIR`.
- Optional features read a `DAISY_*` flag: 1 turns it on, 0 takes it out, unset leaves it and prints how (`DAISY_CHROME_DEVTOOLS`, `DAISY_GATEWAY`, `DAISY_CRON`, `DAISY_INSTALL_APPLE_CLIS`). Shared helpers for the always-on fragments are in `scripts/alwayson/`.
