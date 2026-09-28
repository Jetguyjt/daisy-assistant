# Hermes config fragments

`scripts/setup-hermes.sh` sources every `NN-name.sh` here, in order, after installing the plugin.

- One fragment per feature (`10-memory.sh`, `20-google.sh`, ...).
- Idempotent: running setup twice changes nothing the second time.
- Change settings with `config_set <dotted.key> <value>`. It only writes when the value differs, and backs up `~/.hermes/config.yaml` once per run before the first change.
- Anything else that edits `config.yaml` calls `backup_config` first.
- Never read or print credentials (`auth.json`, `google_token.json`, `.env`).
- Available: `$HERMES` (the CLI), `$HERMES_HOME`, `$REPO_DIR`.
